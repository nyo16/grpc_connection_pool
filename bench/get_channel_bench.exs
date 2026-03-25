# Benchee benchmark for GrpcConnectionPool.get_channel/1
#
# This benchmark measures the hot path performance of get_channel.
# We set up real pool infrastructure (PoolState, ETS, strategies) and
# populate channels directly in ETS to isolate the selection machinery.
#
# Run: mix run bench/get_channel_bench.exs

alias GrpcConnectionPool.{Config, Pool, PoolState}

# Suppress noisy logs during benchmarking
Logger.configure(level: :warning)

# Start GRPC.Client.Supervisor required by grpc lib
{:ok, _} = DynamicSupervisor.start_link(strategy: :one_for_one, name: GRPC.Client.Supervisor)

defmodule BenchHelper do
  @moduledoc false

  def setup_pool(pool_name, size, strategy \\ :round_robin) do
    {:ok, config} =
      Config.local(
        host: "localhost",
        port: 50051,
        pool_size: size,
        pool_name: pool_name
      )

    # Override strategy in config
    config = put_in(config.pool.strategy, strategy)

    {:ok, _pid} = Pool.start_link(config, name: pool_name)
    Process.sleep(300)

    # Populate ETS with mock channels directly (bypassing gRPC connection)
    ets_table = Pool.ets_table_name(pool_name)

    mock_channel = %GRPC.Channel{
      host: "localhost",
      port: 50051,
      scheme: "http",
      adapter: GRPC.Client.Adapters.Gun,
      adapter_payload: %{conn_pid: self()}
    }

    for i <- 0..(size - 1) do
      :ets.insert(ets_table, {{:channel, i}, mock_channel, System.monotonic_time()})
    end

    :ets.insert(ets_table, {:channel_count, size})

    # Also populate channel_slots so the data is consistent
    slots = Map.new(0..(size - 1), fn i -> {self(), i} end)
    :ets.insert(ets_table, {:channel_slots, slots})

    pool_name
  end

  def teardown(pool_name) do
    Pool.stop(pool_name)
    Process.sleep(100)
  end
end

IO.puts(String.duplicate("=", 60))
IO.puts("GrpcConnectionPool Benchmark — OPTIMIZED (v0.3.0)")
IO.puts(String.duplicate("=", 60))
IO.puts("")
IO.puts("Hot path: ETS.lookup(:channel_count) → Strategy.select → ETS.lookup({:channel, idx})")
IO.puts("Zero GenServer.call in hot path!")
IO.puts("")

# ============================================================================
# Benchmark 1: get_channel single-process throughput at different pool sizes
# ============================================================================

IO.puts("Setting up pools for single-process throughput benchmark...")

pools =
  for size <- [5, 10, 25] do
    pool_name = :"bench_single_#{size}"
    BenchHelper.setup_pool(pool_name, size)
    {size, pool_name}
  end

Benchee.run(
  Map.new(pools, fn {size, pool_name} ->
    {"get_channel (pool_size=#{size})", fn -> Pool.get_channel(pool_name) end}
  end),
  time: 5,
  warmup: 2,
  memory_time: 2,
  print: [benchmarking: true, configuration: false]
)

for {_size, pool_name} <- pools, do: BenchHelper.teardown(pool_name)

# ============================================================================
# Benchmark 2: get_channel concurrent throughput
# ============================================================================

IO.puts("\n" <> String.duplicate("=", 60))
IO.puts("Concurrent throughput benchmark...")

concurrent_pool = :bench_concurrent
BenchHelper.setup_pool(concurrent_pool, 10)

Benchee.run(
  %{
    "get_channel (10 concurrent)" => fn ->
      tasks = for _ <- 1..10, do: Task.async(fn -> Pool.get_channel(concurrent_pool) end)
      Task.await_many(tasks, 10_000)
    end,
    "get_channel (50 concurrent)" => fn ->
      tasks = for _ <- 1..50, do: Task.async(fn -> Pool.get_channel(concurrent_pool) end)
      Task.await_many(tasks, 10_000)
    end,
    "get_channel (100 concurrent)" => fn ->
      tasks = for _ <- 1..100, do: Task.async(fn -> Pool.get_channel(concurrent_pool) end)
      Task.await_many(tasks, 10_000)
    end
  },
  time: 5,
  warmup: 2,
  memory_time: 2,
  print: [benchmarking: true, configuration: false]
)

BenchHelper.teardown(concurrent_pool)

# ============================================================================
# Benchmark 3: Pool.status overhead
# ============================================================================

IO.puts("\n" <> String.duplicate("=", 60))
IO.puts("Pool.status benchmark...")

status_pool = :bench_status
BenchHelper.setup_pool(status_pool, 10)

Benchee.run(
  %{
    "Pool.status/1" => fn -> Pool.status(status_pool) end
  },
  time: 3,
  warmup: 1,
  memory_time: 1,
  print: [benchmarking: true, configuration: false]
)

BenchHelper.teardown(status_pool)

# ============================================================================
# Benchmark 4: Strategy comparison
# ============================================================================

IO.puts("\n" <> String.duplicate("=", 60))
IO.puts("Strategy comparison benchmark (pool_size=10)...")

rr_pool = :bench_strategy_rr
BenchHelper.setup_pool(rr_pool, 10, :round_robin)

rand_pool = :bench_strategy_rand
BenchHelper.setup_pool(rand_pool, 10, :random)

p2_pool = :bench_strategy_p2
BenchHelper.setup_pool(p2_pool, 10, :power_of_two)

Benchee.run(
  %{
    "round_robin" => fn -> Pool.get_channel(rr_pool) end,
    "random" => fn -> Pool.get_channel(rand_pool) end,
    "power_of_two" => fn -> Pool.get_channel(p2_pool) end
  },
  time: 5,
  warmup: 2,
  memory_time: 2,
  print: [benchmarking: true, configuration: false]
)

BenchHelper.teardown(rr_pool)
BenchHelper.teardown(rand_pool)
BenchHelper.teardown(p2_pool)

IO.puts("\n" <> String.duplicate("=", 60))
IO.puts("Optimized benchmark complete.")
IO.puts(String.duplicate("=", 60))
