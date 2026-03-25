defmodule GrpcConnectionPool.StrategyTest do
  use ExUnit.Case, async: true

  alias GrpcConnectionPool.Strategy
  alias GrpcConnectionPool.Strategy.{RoundRobin, Random, PowerOfTwo}

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
    setup do
      table = :ets.new(:test_p2, [:public, :set])

      for i <- 0..9 do
        :ets.insert(table, {{:channel, i}, :mock_channel, System.monotonic_time()})
      end

      on_exit(fn ->
        try do
          :ets.delete(table)
        rescue
          ArgumentError -> :ok
        end
      end)

      %{table: table}
    end

    test "init returns :ok" do
      assert PowerOfTwo.init(:test_pool, 10) == :ok
    end

    test "select returns valid indices", %{table: table} do
      state = PowerOfTwo.init(:test_pool, 10)

      for _ <- 1..100 do
        {:ok, idx} = PowerOfTwo.select(state, 10, table)
        assert idx >= 0 and idx < 10
      end
    end

    test "select with channel_count=1 returns 0", %{table: table} do
      state = PowerOfTwo.init(:test_pool, 1)
      assert {:ok, 0} = PowerOfTwo.select(state, 1, table)
    end

    test "select updates last_used timestamp", %{table: table} do
      state = PowerOfTwo.init(:test_pool, 10)

      # Get initial timestamp for channel 0
      [{_, _, ts_before}] = :ets.lookup(table, {:channel, 0})

      # Select many times to ensure channel 0 gets picked at least once
      Process.sleep(1)

      for _ <- 1..100 do
        PowerOfTwo.select(state, 10, table)
      end

      # At least one channel should have been updated
      timestamps =
        for i <- 0..9 do
          [{_, _, ts}] = :ets.lookup(table, {:channel, i})
          ts
        end

      # Some timestamps should have changed
      assert Enum.any?(timestamps, fn ts -> ts > ts_before end)
    end
  end
end
