defmodule Cashmere do
  alias __MODULE__.Partition

  defmacro __using__(options) do
    quote location: :keep, bind_quoted: [options: options] do
      partitions = Keyword.get(options, :partitions, 1)
      purge_interval = Keyword.fetch!(options, :purge_interval)

      alias Cashmere.Partition

      def child_spec([]) do
        Cashmere.child_spec(__MODULE__, unquote(partitions), unquote(purge_interval))
      end

      def get(key) do
        Partition.get(get_key_partition(key), key)
      end

      def put(key, value, expiration) do
        Partition.put(get_key_partition(key), key, value, expiration)
      end

      def read(key, expiration, value_fetcher) do
        with :error <- get(key) do
          case Partition.serializable_put(get_key_partition(key), key, expiration, value_fetcher) do
            :retry ->
              with :error <- get(key), do: {:error, {:cache, :retry_failure}}

            result ->
              result
          end
        end
      end

      def dirty_read(key, expiration, value_fetcher) do
        with :error <- get(key) do
          case value_fetcher.() do
            {:ok, value} = result ->
              put(key, value, expiration)
              result

            {:error, reason} = error ->
              error
          end
        end
      end

      @compile {:inline, [get_key_partition: 1]}

      defp get_key_partition(key) do
        Partition.get_name(__MODULE__, :erlang.phash2(key, unquote(partitions)))
      end
    end
  end

  def child_spec(cache, partitions, purge_interval) do
    children =
      for index <- 0..(partitions - 1) do
        {Partition, {Partition.get_name(cache, index), purge_interval}}
      end

    %{
      id: cache,
      start: {Supervisor, :start_link, [children, [strategy: :one_for_one]]},
      type: :supervisor
    }
  end
end
