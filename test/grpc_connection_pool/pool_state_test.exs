defmodule GrpcConnectionPool.PoolStateTest do
  @moduledoc """
  Exercises the serialized slot lifecycle in `PoolState`.

  These tests target the concurrency bug where slot claim/release used to be
  non-atomic read-modify-write run in worker processes: concurrent registers
  could collide on the same slot, leaving `:channel_count` higher than the
  number of populated `{:channel, index}` entries (so `get_channel/1` returned
  `:not_connected` for healthy pools). With registration serialized through the
  GenServer, slots must stay a contiguous `0..count-1` range and the count must
  always equal the number of populated slots.
  """
  use ExUnit.Case, async: false

  alias GrpcConnectionPool.PoolState

  setup do
    pool_name = :"PoolStateTest.#{:erlang.unique_integer([:positive])}"
    {:ok, config} = GrpcConnectionPool.Config.local(pool_size: 1, pool_name: pool_name)

    {:ok, pid} = PoolState.start_link(pool_name: pool_name, config: config)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    %{pool_name: pool_name, ets_table: :"#{pool_name}.ETS"}
  end

  defp channel_count(ets_table) do
    case :ets.lookup(ets_table, :channel_count) do
      [{:channel_count, c}] -> c
      [] -> 0
    end
  end

  defp populated_slots(ets_table) do
    :ets.tab2list(ets_table)
    |> Enum.flat_map(fn
      {{:channel, idx}, _channel, _last_used} -> [idx]
      _ -> []
    end)
    |> Enum.sort()
  end

  defp assert_consistent(ets_table) do
    count = channel_count(ets_table)
    slots = populated_slots(ets_table)

    assert slots == Enum.to_list(0..(count - 1)//1),
           "expected contiguous slots 0..#{count - 1}, got #{inspect(slots)} (count=#{count})"

    count
  end

  test "concurrent registration yields contiguous slots with no gaps or duplicates", %{
    pool_name: pool_name,
    ets_table: ets_table
  } do
    n = 25

    slots =
      1..n
      |> Task.async_stream(
        fn i ->
          {:ok, slot} = PoolState.register_channel(pool_name, self(), {:mock_channel, i})
          slot
        end,
        max_concurrency: n,
        ordered: false
      )
      |> Enum.map(fn {:ok, slot} -> slot end)
      |> Enum.sort()

    # Every worker got a distinct slot, forming a contiguous 0..n-1 range.
    assert slots == Enum.to_list(0..(n - 1))

    # ETS is internally consistent: count matches populated slots.
    assert channel_count(ets_table) == n
    assert assert_consistent(ets_table) == n
  end

  test "register is idempotent per pid (no double count on re-register)", %{
    pool_name: pool_name,
    ets_table: ets_table
  } do
    {:ok, slot1} = PoolState.register_channel(pool_name, self(), :chan_a)
    {:ok, slot2} = PoolState.register_channel(pool_name, self(), :chan_b)

    assert slot1 == slot2
    assert channel_count(ets_table) == 1

    # Channel was refreshed in place.
    assert [{{:channel, ^slot1}, :chan_b, _}] = :ets.lookup(ets_table, {:channel, slot1})
  end

  test "releasing a middle slot compacts the array and keeps count correct", %{
    pool_name: pool_name,
    ets_table: ets_table
  } do
    pids = for _ <- 1..5, do: spawn(fn -> Process.sleep(:infinity) end)

    for {pid, i} <- Enum.with_index(pids) do
      {:ok, _} = PoolState.register_channel(pool_name, pid, {:mock_channel, i})
    end

    assert assert_consistent(ets_table) == 5

    # Release a non-final slot — the highest channel should fill the gap.
    middle_pid = Enum.at(pids, 1)
    :ok = PoolState.unregister_channel(pool_name, middle_pid)

    assert assert_consistent(ets_table) == 4

    # Releasing an already-released pid is a no-op (count unchanged).
    :ok = PoolState.unregister_channel(pool_name, middle_pid)
    assert assert_consistent(ets_table) == 4

    Enum.each(pids, &Process.exit(&1, :kill))
  end

  test "interleaved concurrent register/unregister stays consistent", %{
    pool_name: pool_name,
    ets_table: ets_table
  } do
    pids = for _ <- 1..20, do: spawn(fn -> Process.sleep(:infinity) end)

    for {pid, i} <- Enum.with_index(pids) do
      {:ok, _} = PoolState.register_channel(pool_name, pid, {:mock_channel, i})
    end

    assert assert_consistent(ets_table) == 20

    # Concurrently release half of them.
    {to_release, _keep} = Enum.split(pids, 10)

    to_release
    |> Task.async_stream(fn pid -> PoolState.unregister_channel(pool_name, pid) end,
      max_concurrency: 10,
      ordered: false
    )
    |> Stream.run()

    assert assert_consistent(ets_table) == 10

    Enum.each(pids, &Process.exit(&1, :kill))
  end
end
