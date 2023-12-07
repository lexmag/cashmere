defmodule Cashmere.Partition do
  @moduledoc false

  use GenServer

  alias __MODULE__.Lock

  def child_spec({partition, _purge_interval} = arg) do
    children = [
      {Lock, partition},
      %{
        id: partition,
        start: {GenServer, :start_link, [__MODULE__, arg]}
      }
    ]

    %{
      id: Module.concat(partition, Supervisor),
      start: {Supervisor, :start_link, [children, [strategy: :one_for_one]]},
      type: :supervisor
    }
  end

  def get_name(cache, index) do
    Module.concat(cache, "Partition" <> Integer.to_string(index))
  end

  def init({partition, purge_interval} = state) do
    ^partition =
      :ets.new(partition, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])

    schedule_purging(purge_interval)
    {:ok, state}
  end

  def serializable_put(partition, key, expiration, value_fetcher) do
    with :ok <- Lock.acquire(partition, key) do
      try do
        value_fetcher.()
      else
        {:ok, value} = result ->
          put(partition, key, value, expiration)
          Lock.release(partition, key, :retry)
          result

        {:error, _reason} = error ->
          Lock.release(partition, key, error)
          error
      catch
        kind, reason ->
          Lock.release(partition, key, {:error, {:cache, :callback_failure}})
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end
  end

  def get(partition, key) do
    case :ets.lookup(partition, key) do
      [entry] ->
        {:ok, elem(entry, 1)}

      [] ->
        :error
    end
  end

  def put(partition, key, value, expiration) do
    entry =
      if expiration == :infinity do
        {key, value}
      else
        expire_after =
          :millisecond
          |> System.monotonic_time()
          |> Kernel.+(expiration)

        {key, value, expire_after}
      end

    :ets.insert_new(partition, entry)
    :ok
  end

  def handle_info(:purge_expired, {partition, purge_interval} = state) do
    schedule_purging(purge_interval)

    current_time = System.monotonic_time(:millisecond)

    :ets.select_delete(partition, [
      {
        {:_, :_, :"$3"},
        [{:"=<", :"$3", current_time}],
        [true]
      }
    ])

    {:noreply, state}
  end

  defp schedule_purging(:infinity), do: :ok

  defp schedule_purging(purge_interval) do
    Process.send_after(self(), :purge_expired, purge_interval)
    :ok
  end
end
