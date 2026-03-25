# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-03-24

### Added
- **Zero GenServer.call hot path** — channels stored directly in ETS for O(1) indexed access, eliminating the GenServer.call bottleneck on every `get_channel` request
- **Pluggable connection strategies** via `GrpcConnectionPool.Strategy` behaviour:
  - `:round_robin` (default) — lock-free atomics-based round-robin
  - `:random` — random selection, good for avoiding hot-spotting
  - `:power_of_two` — power-of-two-choices with least-recently-used tiebreak
  - Custom strategies supported via behaviour implementation
- **`:persistent_term` for pool config** — zero-copy reads for configuration data
- **ETS with read/write concurrency** — optimized concurrent access flags
- **`PoolState` GenServer** — dedicated ETS table owner for crash resilience
- **`TelemetryReporter` GenServer** — replaced recursive `:timer.sleep` telemetry loop with a proper GenServer using `Process.send_after`
- **`await_ready/2`** — blocks until at least one channel is connected or timeout, useful for application startup
- **Stale scaling lock detection** — scaling locks older than 30 seconds are automatically released
- **`max_reconnect_attempts` config** — workers crash after N consecutive connection failures instead of the fragile `crash_after_reconnect_attempt` timer
- **Benchee benchmarks** — `bench/get_channel_bench.exs` for measuring hot path performance
- **Strategy tests** — comprehensive tests for all three built-in strategies
- **CI/CD pipeline** — GitHub Actions with compile, format, credo, test, dialyzer, and auto-publish to Hex on tag push

### Changed
- **4.3x–5.8x faster `get_channel`** — single-process throughput improved from ~470K ips to ~2M ips
- **O(n) scaling eliminated** — pool_size=25 was 38% slower than pool_size=5, now only 2% slower
- **44–58% lower latency under concurrency** — 100 concurrent callers: median 553μs → 312μs, p99 1035μs → 439μs
- **28–56% less memory per call** — memory now constant regardless of pool size (was O(n))
- **Pool.status 2.5x faster** — reads from ETS channel_count instead of Registry.lookup
- Pool supervision tree restructured: PoolState starts first, then Registry, DynamicSupervisor, workers, and TelemetryReporter

### Removed
- `crash_after_reconnect_attempt` message — replaced by `max_reconnect_attempts` config with clean `{:stop, reason, state}` on exhaustion

## [0.2.3] - 2025-01-29

### Added
- Enhanced telemetry events for better observability:
  - `[:grpc_connection_pool, :pool, :init]` - Pool initialization with size and endpoint
  - `[:grpc_connection_pool, :channel, :ping]` - Ping health check with duration and result
  - `[:grpc_connection_pool, :channel, :gun_down]` - Gun connection down events with reason and protocol
  - `[:grpc_connection_pool, :channel, :gun_error]` - Gun error events with reason
  - `[:grpc_connection_pool, :channel, :reconnect_scheduled]` - Reconnection scheduling with delay and attempt count
- Reconnect attempt tracking in worker state
- Comprehensive telemetry documentation in README
- Telemetry test suite

## [0.2.2] - 2025-01-29

### Added
- Support for gRPC client interceptors in endpoint configuration (thanks [@arctarus](https://github.com/arctarus))
- Comprehensive tests for interceptors feature
- CHANGELOG.md file

## [0.2.1] - 2025-11-22

### Fixed
- Handle GRPC v0.11.5 FunctionClauseError during disconnect

## [0.2.0] - 2025-11-22

### Added
- Dynamic pool scaling feature

## [0.1.6] - 2025-11-22

### Fixed
- Handle GenServer exit gracefully in connection cleanup

## [0.1.5] - 2025-11-21

### Changed
- Refactored to replace Poolex with DynamicSupervisor
- Added conn_grpc features
- Fixed documentation LICENSE reference warnings

## [0.1.4] - 2025-11-19

### Changed
- Updated dependencies: poolex to 1.4.2, grpc to 0.11.5
- Changed gRPC connection logs from info to debug level

### Added
- `suppress_connection_errors` config option for GCP endpoints

## [0.1.3] - 2025-11-18

### Added
- License file

## [0.1.2] - 2025-11-18

### Added
- Comprehensive README with complete configuration examples and architecture details

## [0.1.0] - 2025-11-18

### Added
- Initial release: Complete GrpcConnectionPool library
- Configuration module with support for production, local, and custom environments
- Connection pooling with DynamicSupervisor
- Automatic connection warming and health monitoring
- Retry logic with exponential backoff and jitter
- Telemetry integration for metrics
