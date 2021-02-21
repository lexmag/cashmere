defmodule Cashmere.Partition.Lock do
  use GenServer

  defmodule Replier do
    use GenServer

    def start_link(callers) do
      GenServer.start_link(__MODULE__, callers)
    end

    def init(callers), do: {:ok, callers}

    def release(replier, key, result) do
      GenServer.cast(replier, {:release, key, result})
    end

    def handle_cast({:release, key, result}, callers) do
      for {_key, caller} <- :ets.take(callers, key) do
        GenServer.reply(caller, result)
      end

      {:noreply, callers}
    end
  end

  defstruct [:callers, :replier, keys: %{}]

  def start_link(partition) do
    GenServer.start_link(__MODULE__, nil, name: get_name(partition))
  end

  def init(nil) do
    callers = :ets.new(:callers, [:bag, :public])
    {:ok, replier} = __MODULE__.Replier.start_link(callers)
    {:ok, %__MODULE__{callers: callers, replier: replier}}
  end

  def acquire(partition, key) do
    partition
    |> get_name()
    |> GenServer.call({:acquire, key}, 60_000)
  end

  def release(partition, key, action) do
    partition
    |> get_name()
    |> GenServer.cast({:release, key, action})
  end

  def handle_call({:acquire, key}, from, %{callers: callers, keys: keys} = state) do
    case keys do
      %{^key => _monitor_ref} ->
        :ets.insert(callers, {key, from})
        {:noreply, state}

      _ ->
        {pid, _tag} = from
        ref = Process.monitor(pid)
        {:reply, :ok, %{state | keys: Map.put(keys, key, ref)}}
    end
  end

  def handle_cast({:release, key, result}, %{keys: keys} = state) do
    ref = Map.fetch!(keys, key)
    Process.demonitor(ref, [:flush])
    handle_release(key, result, state)
  end

  def handle_info({:DOWN, ref, _, _, _}, %{keys: keys} = state) do
    {key, _ref} = Enum.find(keys, &match?({_key, ^ref}, &1))
    handle_release(key, {:error, {:cache, :owner_failure}}, state)
  end

  @compile {:inline, [handle_release: 3, get_name: 1]}

  defp handle_release(key, result, %{keys: keys, replier: replier} = state) do
    Replier.release(replier, key, result)
    {:noreply, %{state | keys: Map.delete(keys, key)}}
  end

  defp get_name(partition) do
    Module.concat(partition, __MODULE__)
  end
end
