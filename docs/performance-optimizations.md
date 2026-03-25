# Performance Optimizations — v0.3.0

This document details the bottlenecks found in v0.2.x and the optimizations implemented in v0.3.0, with benchmark results showing the improvements.

## Bottlenecks Found in v0.2.x

| # | Issue | Location | Severity |
|---|-------|----------|----------|
| 1 | **GenServer.call on every `get_channel`** — serialized all requests through Worker mailbox | `pool.ex` / `worker.ex` | Critical |
| 2 | **`Enum.at/2` is O(n)** on Registry.lookup result list | `pool.ex` | High |
| 3 | **Registry.lookup scans all entries** on every call | `pool.ex` | High |
| 4 | **Round-robin counter vs channels list race** — counter wraps on stale pool_size | `pool.ex` | Medium |
| 5 | **Only round-robin strategy** — no pluggable selection | `pool.ex` | Design gap |
| 6 | **Telemetry loop uses recursive `:timer.sleep`** — crashes kill the loop silently | `pool.ex` | Medium |
| 7 | **`crash_after_reconnect_attempt`** schedules crash 100ms after reconnect delay — fragile timing | `worker.ex` | Medium |
| 8 | **ETS table is `:public` without concurrency flags** — no read/write concurrency optimization | `pool.ex` | Low |
| 9 | **Scaling lock can become zombie** if process crashes before `after` block | `pool.ex` | Low |
| 10 | **No connection readiness signaling** — pool is "up" before any connection succeeds | Pool architecture | Design gap |

## Old Hot Path (v0.2.x)

```
Pool.get_channel()
  → Registry.lookup (scan all entries → list)          # O(n)
  → length(channels)                                    # O(n)
  → :ets.update_counter (round-robin)                   # O(1) ✓
  → Enum.at(channels, index)                            # O(n)
  → Worker.get_channel(pid) → GenServer.call            # SERIALIZED!
```

**5 operations, 3 are O(n), 1 is a GenServer bottleneck.**

## New Hot Path (v0.3.0)

```
Pool.get_channel()
  → :ets.lookup(table, :channel_count)                  # O(1)
  → :persistent_term.get(strategy_mod)                   # O(1), zero-copy
  → Strategy.select (e.g. :atomics.add_get)             # O(1), lock-free
  → :ets.lookup(table, {:channel, index})               # O(1)
  → return channel directly                             # no GenServer!
```

**4 operations, all O(1), zero GenServer calls.**

## Benchmark Results

All benchmarks run with `Benchee ~> 1.0` using mock channels in ETS to isolate pool machinery from network I/O.

### Single-Process `get_channel` Throughput

| Pool Size | v0.2.x (ips) | v0.3.0 (ips) | Speedup |
|-----------|-------------|--------------|---------|
| 5         | 473,810     | **2,030,000** | **4.3x** |
| 10        | 425,890     | **2,050,000** | **4.8x** |
| 25        | 343,510     | **1,990,000** | **5.8x** |

### O(n) Scaling Eliminated

| Pool Size | v0.2.x avg | v0.3.0 avg | v0.2.x vs pool=5 | v0.3.0 vs pool=5 |
|-----------|-----------|-----------|-------------------|-------------------|
| 5         | 2.11 μs   | 494 ns    | baseline          | baseline          |
| 10        | 2.35 μs   | 489 ns    | 1.11x slower      | **1.01x** (flat!) |
| 25        | 2.91 μs   | 503 ns    | 1.38x slower      | **1.02x** (flat!) |

Pool size 25 was **38% slower** than pool size 5 in v0.2.x. In v0.3.0 it's **only 2% slower** — effectively constant time.

### Concurrent Throughput (10 workers, pool_size=10)

| Concurrency | v0.2.x ips | v0.3.0 ips | Speedup |
|-------------|-----------|-----------|---------|
| 10 callers  | 18,430    | **35,030** | **1.9x** |
| 50 callers  | 3,580     | **6,170**  | **1.7x** |
| 100 callers | 1,650     | **3,130**  | **1.9x** |

### Latency Under Concurrency (100 callers)

| Percentile | v0.2.x   | v0.3.0   | Improvement |
|------------|---------|---------|-------------|
| median     | 553 μs  | **312 μs** | **44% lower** |
| p99        | 1,035 μs | **439 μs** | **58% lower** |

### Memory Per Call

| Pool Size | v0.2.x | v0.3.0 | Reduction |
|-----------|--------|--------|-----------|
| 5         | 1.00 KB | **0.72 KB** | **28%** |
| 10        | 1.25 KB | **0.72 KB** | **42%** |
| 25        | 1.65 KB | **0.72 KB** | **56%** |

Memory is now **constant regardless of pool size** (was O(n) due to list allocation from Registry.lookup).

### Pool.status

| Metric | v0.2.x | v0.3.0 | Improvement |
|--------|--------|--------|-------------|
| ips    | 1.47M  | **3.71M** | **2.5x faster** |
| memory | 704 B  | **200 B** | **3.5x less** |

### Strategy Comparison (pool_size=10)

| Strategy     | ips   | avg    | Memory |
|-------------|-------|--------|--------|
| round_robin | 1.91M | 522 ns | 0.72 KB |
| random      | 1.87M | 534 ns | 1.05 KB |
| power_of_two | 1.08M | 925 ns | 2.05 KB |

Round-robin is fastest due to atomics. Power-of-two trades ~1.8x overhead for better load distribution under uneven workloads.

## Architecture Changes

### Before (v0.2.x)

```
Pool.Supervisor (one_for_one)
├── Registry
├── DynamicSupervisor → Workers
├── WorkerStarter (Task, temporary)
└── TelemetryLoop (Task, permanent, recursive sleep)
```

### After (v0.3.0)

```
Pool.Supervisor (one_for_one)
├── PoolState (GenServer — owns ETS, persistent_term setup)
├── Registry
├── DynamicSupervisor → Workers
├── WorkerStarter (Task, temporary)
└── TelemetryReporter (GenServer, Process.send_after)
```

### Key Changes

1. **PoolState** — Dedicated GenServer owns the ETS table with `{:read_concurrency, true}` and `{:write_concurrency, true}`. Stores config in `:persistent_term` for zero-copy reads. Manages channel slot assignment.

2. **Workers write to ETS directly** — On connect, workers claim a slot via `PoolState.claim_slot/2` and insert their channel into ETS. On disconnect, they release the slot and compact the array.

3. **Channel array** — Channels stored as `{:channel, 0}`, `{:channel, 1}`, ... for O(1) indexed access. A `:channel_count` key tracks the number of connected channels.

4. **Atomics counter** — The round-robin strategy uses `:atomics.add_get/3` for lock-free, contention-free counter increments (no ETS writes in the hot path).

5. **TelemetryReporter** — Replaced recursive function + `:timer.sleep` with a proper GenServer that uses `Process.send_after`. If a tick crashes, the GenServer recovers and continues.

## Running Benchmarks

```bash
mix run bench/get_channel_bench.exs
```

This runs all benchmarks: single-process throughput at different pool sizes, concurrent throughput, pool status, and strategy comparison.
