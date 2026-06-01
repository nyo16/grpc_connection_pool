defmodule GrpcConnectionPool.StrategyTest do
  use ExUnit.Case, async: true

  alias GrpcConnectionPool.Strategy
  alias GrpcConnectionPool.Strategy.{PowerOfTwo, Random, RoundRobin}

  describe "Strategy.resolve/1" do
    test "resolves :round_robin to module" do
      assert Strategy.resolve(:round_robin) == RoundRobin
    end

    test "resolves :random to module" do
      assert Strategy.resolve(:random) == Random
    end

    test "resolves :power_of_two to module" do
      assert Strategy.resolve(:power_of_two) == PowerOfTwo
    end

    test "passes through custom module" do
      assert Strategy.resolve(MyApp.CustomStrategy) == MyApp.CustomStrategy
    end
  end

  describe "RoundRobin" do
    test "init returns an atomics ref" do
      state = RoundRobin.init(:test_pool, 10)
      assert is_reference(state)
    end

    test "select returns sequential indices that wrap around" do
      state = RoundRobin.init(:test_pool, 10)

      indices =
        for _ <- 1..20 do
          {:ok, idx} = RoundRobin.select(state, 5, :unused)
          idx
        end

      # Should cycle through indices, starting at 1 (add_get adds before reading)
      # The exact starting point doesn't matter — what matters is the cycle
      assert length(Enum.uniq(indices)) == 5
      assert Enum.all?(indices, &(&1 >= 0 and &1 < 5))

      # Verify sequential pattern: each index should differ from previous by 1 (mod 5)
      pairs = Enum.zip(indices, tl(indices))
      assert Enum.all?(pairs, fn {a, b} -> rem(b - a + 5, 5) == 1 or (a == 4 and b == 0) end)
    end
  end

  describe "Random" do
    test "init returns :ok" do
      assert Random.init(:test_pool, 10) == :ok
    end

    test "select returns valid indices" do
      state = Random.init(:test_pool, 10)

      for _ <- 1..100 do
        {:ok, idx} = Random.select(state, 10, :unused)
        assert idx >= 0 and idx < 10
      end
    end

    test "select with channel_count=1 always returns 0" do
      state = Random.init(:test_pool, 1)

      for _ <- 1..10 do
        assert {:ok, 0} = Random.select(state, 1, :unused)
      end
    end
  end

  describe "PowerOfTwo" do
    # Load tracking is now in :atomics (no ETS), so select/3 ignores ets_table.
    @ets :unused

    test "init returns an atomics ref sized to at least pool_size" do
      assert {ref, size} = PowerOfTwo.init(:test_pool, 10)
      assert is_reference(ref)
      assert size >= 10
    end

    test "select returns valid indices" do
      state = PowerOfTwo.init(:test_pool, 10)

      for _ <- 1..100 do
        {:ok, idx} = PowerOfTwo.select(state, 10, @ets)
        assert idx >= 0 and idx < 10
      end
    end

    test "select with channel_count=1 returns 0" do
      state = PowerOfTwo.init(:test_pool, 1)
      assert {:ok, 0} = PowerOfTwo.select(state, 1, @ets)
    end

    test "select increments the chosen slot's counter" do
      {ref, _size} = state = PowerOfTwo.init(:test_pool, 10)

      total_before = Enum.sum(for i <- 1..10, do: :atomics.get(ref, i))
      assert total_before == 0

      for _ <- 1..100, do: PowerOfTwo.select(state, 10, @ets)

      # Exactly one counter is incremented per select.
      total_after = Enum.sum(for i <- 1..10, do: :atomics.get(ref, i))
      assert total_after == 100
    end

    test "stays valid (no crash) when channel_count exceeds the counter array" do
      # Force a tiny counter array, then select across more channels than slots.
      Application.put_env(:grpc_connection_pool, :power_of_two_max_slots, 2)
      on_exit(fn -> Application.delete_env(:grpc_connection_pool, :power_of_two_max_slots) end)

      {_ref, size} = state = PowerOfTwo.init(:test_pool, 1)
      assert size == 2

      for _ <- 1..100 do
        {:ok, idx} = PowerOfTwo.select(state, 10, @ets)
        assert idx >= 0 and idx < 10
      end
    end
  end
end
