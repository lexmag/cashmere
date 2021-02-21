defmodule CashmereTest do
  use ExUnit.Case

  defmodule TestCache do
    use Cashmere, purge_interval: 50
  end

  setup_all do
    {:ok, _} = start_supervised(TestCache)
    :ok
  end

  defp spawn_read(key, value_fetcher) do
    test_pid = self()

    value_fetcher = fn ->
      result = value_fetcher.()
      send(test_pid, {:value_fetcher, key})
      result
    end

    spawn_monitor(fn ->
      result = TestCache.read(key, 100, value_fetcher)
      send(test_pid, {:read, key, result})
    end)
  end

  describe "read/4" do
    test "stores values" do
      result = {:ok, :foo}
      test_key1 = make_ref()
      test_key2 = make_ref()

      spawn_read(test_key1, fn ->
        Process.sleep(100)
        result
      end)

      spawn_read(test_key1, fn -> result end)
      spawn_read(test_key2, fn -> result end)

      assert_receive {:value_fetcher, ^test_key2}
      assert_receive {:value_fetcher, ^test_key1}, 125
      refute_receive {:value_fetcher, _key}, 25

      assert_receive {:read, ^test_key2, ^result}
      assert_receive {:read, ^test_key1, ^result}
      assert_receive {:read, ^test_key1, ^result}
    end

    test "handles errors" do
      error = {:error, :test}
      test_key = make_ref()

      spawn_read(test_key, fn ->
        Process.sleep(100)
        error
      end)

      spawn_read(test_key, fn -> {:ok, :foo} end)

      assert_receive {:read, ^test_key, ^error}, 125
      assert_receive {:read, ^test_key, ^error}, 25
    end

    @tag :capture_log
    test "handles crashes" do
      test_key = make_ref()

      {_pid, ref} =
        spawn_read(test_key, fn ->
          Process.sleep(100)
          raise "fail"
        end)

      spawn_read(test_key, fn -> {:ok, :foo} end)

      assert_receive {:read, ^test_key, {:error, {:cache, :callback_failure}}}, 125
      assert_receive {:DOWN, ^ref, _, _, {%RuntimeError{message: "fail"}, _}}, 25

      {pid, ref} = spawn_read(test_key, fn -> Process.sleep(:infinity) end)
      spawn_read(test_key, fn -> {:ok, :foo} end)

      Process.sleep(100)
      Process.exit(pid, :brutal_kill)

      assert_receive {:read, ^test_key, {:error, {:cache, :owner_failure}}}, 125
      assert_receive {:DOWN, ^ref, _, _, :brutal_kill}, 25
    end
  end
end
