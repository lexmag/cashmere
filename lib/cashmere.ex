defmodule Cashmere do
  @moduledoc """
  This module provides the interface to work with Cashmere, a high performance
  in-memory caching solution.

  To get started with Cashmere, you need to create a module that calls
  `use Cashmere`, like this:

      defmodule MyApp.Cache do
        use Cashmere, purge_interval: _milliseconds = 100, partitions: 4
      end

  This way, `MyApp.Cache` becomes a Cashmere cache with four partitions. It
  comes with the `child_spec/1` function that returns child specification
  that allows us to start `MyApp.Cache` directly under a supervision tree,
  and many other functions to work with the cache as documented in this
  module.

  Usually you won't call `child_spec/1` directly but just add the cache to the
  application supervision tree.

      def start(_type, _args) do
        children = [
          MyApp.Cache,
          # ...
        ]

        Supervisor.start_link(children, strategy: :one_for_one)
      end

  There are a few configuration values available for `use Cashmere`:

  * `purge_interval` — (required) the interval in milliseconds when expired items
    in the cache are purged. Note that intervals are not exact, but _at least_ as
    long as the interval is passed.
  * `partitions` — the amount of paritions of this cache. Defaults to `1`.

  """

  alias __MODULE__.Partition

  @type key() :: any()
  @type value() :: any()

  @typedoc "Expiration time (in milliseconds or `:infinity`)."
  @type expiration() :: pos_integer() | :infinity

  @doc """
  Returns the child specification for the cache.

  See the "Child specification" section in the `Supervisor` module for more detailed information.
  """
  @callback child_spec(options :: Keyword.t()) :: Supervisor.child_spec()

  @doc """
  Retrieves the value by a specific `key` from the cache.

  ### Example

      iex> MyApp.Cache.get(:name)
      {:ok, "cashmere"}
      iex> MyApp.Cache.get(:does_not_exist)
      :error

  """
  @callback get(key()) :: {:ok, value()} | :error

  @doc """
  Puts the `value` under `key` in the cache, with the given `expiration` (in milliseconds
  or `:infinity`).

  To put a value that never expires, use `:infinity` for `expiration`.

  Note that entries in the cache are purged periodically with the configured `purge_interval`,
  it's possible for the value to exist for a short while after the given expiration time.

  ## Examples

      iex> MyApp.Cache.put(:name, "cashmere", _30_seconds = 30_000)
      :ok

  """
  @callback put(key(), value(), expiration()) :: :ok

  @doc """
  Retrieves the value stored under `key`, invokes `value_fetcher` _serializably_ if
  not found, and puts the returned value in the cache under `key`, with the given
  `expiration` (in milliseconds or `:infinity`).

  "Serializably" means that there will be _only one_ invocation of `value_fetcher` at
  a point in time, amongst many concurrent `read/3` calls with the same `key`, in the
  current runtime instance. This can be used as a possible mitigation for
  [cache stampedes](https://en.wikipedia.org/wiki/Cache_stampede) under very high load,
  to help avoiding cascading failures under very high load when massive cache misses
  happen for hot keys.

  Note that this function is subjected to some minor performance overhead. Most of the
  time when it is not necessary, consider using `dirty_read/3`.

  There are several possible errors:

  * `{:cache, :callback_failure}` — the invocation of `value_fetcher` raised an exception.
  * `{:cache, :retry_failure}` — the invocation of `value_fetcher` succeeded but the value
    could not be retrieved.
  * `reason` — the invocation of `value_fetcher` returned an error with `reason`.

  ## Examples

      iex> MyApp.Cache.read(:name, 30_000, fn ->
      ...>   very_heavy_computation()
      ...> end)
      {:ok, "cashmere"}

  """
  @callback read(
              key(),
              expiration(),
              value_fetcher :: (() -> {:ok, result} | {:error, reason})
            ) ::
              {:ok, result}
              | {:error, reason}
              | {:error, {:cache, :callback_failure}}
              | {:error, {:cache, :retry_failure}}
            when result: value(), reason: any()

  @doc """
  Retrieves the value stored under `key`, invokes `value_fetcher` if not found, and
  puts the returned value in the cache under `key`, with the given `expiration` (in
  milliseconds or `:infinity`).

  Note that since `value_fetcher` will always be invoked in case of a cache miss, it
  is subjected to cascading failures under very high load. Use `read/3` if you need
  serializable invocation.

  ## Examples

      iex> MyApp.Cache.dirty_read(:name, 30_000, fn ->
      ...>   very_heavy_computation()
      ...> end)
      {:ok, "cashmere"}

  """
  @callback dirty_read(
              key(),
              expiration(),
              value_fetcher :: (() -> {:ok, result} | {:error, reason})
            ) :: {:ok, result} | {:error, reason}
            when result: value(), reason: any()

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

  @doc false
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
