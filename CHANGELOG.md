# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.5.2] - 2026-08-06

### Security
- **`cowlib` 2.18.0 → 2.19.0 fixes CVE-2026-59248 (HIGH):** unbounded HPACK/QPACK
  prefixed-integer decoding allowed a memory-exhaustion DoS. This one is squarely in
  the pool's path — gRPC is HTTP/2, so gun decodes HPACK from whatever the *server*
  sends, and a malicious or compromised endpoint could exhaust client memory. Upgrading
  is recommended for all users.
- **`cowboy` 2.17.0 → 2.18.0 fixes CVE-2026-65624 (MEDIUM)** (`max_headers` bypass via
  duplicate header names). Test-only: cowboy backs the h2c test server and is not a
  runtime dependency.
- **Still open upstream, and why it is not actionable here:** cowlib carries two
  advisories with no fixed release — CVE-2026-43966 (MEDIUM, HTTP response splitting via
  non-VCHAR bytes in `cow_http_struct_hd:escape_string/2`) and CVE-2026-43969 (LOW, cookie
  request-header injection). Both are mitigated a layer up: gun ≥ 2.4.0 rejects CR/LF in
  header values by default (`invalid_request_headers`), and the lock has pinned gun 2.4.1
  since 0.5.1. Note that scanners reading the GitHub advisory will flag *any* gun release
  as vulnerable to CVE-2026-43966 — that record lists gun's patched version as "2.16.0",
  a cowboy version number, so no gun release can satisfy it. The ERLEF CNA record (the
  issuing CNA) is the accurate one: "applications using gun 2.4.0 or later are protected".

### Changed
- **`grpc` 1.0.2 → 1.0.3** (and `grpc_core` to match), plus `ranch` 2.2.0 → 2.2.1.
- **`gun` stays at 2.4.1**, which is the latest release the pool can use: grpc 1.0.3 still
  requires `gun ~> 2.4.0`, so gun 2.5.0 is out of range on grpc 1.x. Confirmed by
  resolution, not by inspection — `mix deps.update gun` leaves 2.4.1 in place.
- **Raised the `:gun` requirement from `~> 2.2` to `~> 2.4`** (also updated in the README
  install snippet). gun 2.4.0 is where `invalid_request_headers` landed — the validation
  that mitigates CVE-2026-43966, which has no cowlib-side fix — so the floor is a security
  boundary rather than housekeeping. Consumers on grpc 1.0 were already resolving to 2.4.x
  because grpc requires `gun ~> 2.4.0`; this makes the real floor explicit and stops a
  stale lock from silently sitting on 2.2.x.
- **Typespec:** grpc 1.0.3 removed the `@type t` from `GRPC.Channel`, leaving the bare
  struct with no named type to reference. `GrpcConnectionPool.Pool` now publishes its own
  `@type channel :: %GRPC.Channel{}`, and `Pool.get_channel/1` specs `{:ok, channel()}`.
  Runtime behaviour is unchanged; only the spec's spelling moved.
- **Dialyzer filters removed, as designed.** grpc 1.0.3 fixed the `finalize_connection/2`
  success-typing regression that 1.0.2 introduced, so both entries in
  `.dialyzer_ignore.exs` went unused and `list_unused_filters: true` failed the build —
  exactly the expiry the 0.5.1 notes described. The list is now empty and dialyzer is
  clean with no suppressions.

### Fixed
- **Test suite no longer depends on port 50051 being closed.** The two pool-scaling test
  files hardcoded `port: 50_051` for pools whose workers are never meant to connect. On
  any machine where that port is *blackholed* rather than closed — a Docker/OrbStack
  forward, VPN, or packet filter that drops the SYN instead of refusing it — every connect
  burned the full 3s timeout instead of failing in ~0ms, and the resulting backoff churn
  starved the 5s deadlines in `telemetry_test.exs`, failing three unrelated tests. Ports
  now come from a new `TestServer.dead_port/0`, which binds port 0 and closes it so the
  connect is genuinely refused. Full suite: 16.5s → 2.2s, green across seeds, and 78/78
  with `mix test --include emulator` against a live Pub/Sub emulator.

## [0.5.1] - 2026-07-26

### Fixed
- **Docs:** documented the one supervision-tree change grpc 1.0 requires — a leftover
  `{GRPC.Client.Supervisor, []}` child spec now crashes at boot, because grpc 1.0 removed
  that module and starts a `DynamicSupervisor` under the same name itself. Consumers were
  reading the crash as an unfixable version conflict and pinning grpc back to 0.11.x. See
  the install note and the Troubleshooting entry in the README, plus the 0.5.0 upgrade
  notes below.
- `mix docs` is warning-free again: qualified `GrpcConnectionPool.Config.production/1` and
  removed the autolink to the (deliberately) nonexistent `execute/1` in the 0.4.0 entries.

### Changed
- `CHANGELOG.md` is now shipped in the Hex package (it was already a docs extra).
- **Dialyzer filters** (`.dialyzer_ignore.exs`, wired up via `ignore_warnings` +
  `list_unused_filters`): grpc 1.0.2 extracted `finalize_connection/2` out of
  `GRPC.Client.Connection.connect/2`, and analyzed alone that function's success typing
  rejects the still-`nil` virtual channel `connect/2` passes it. Dialyzer concludes the
  call never returns, narrows `GRPC.Stub.connect/2` to `{:error, _}`, and then flags the
  pool's success branch and `monitor_connection/1` as dead code. Both warnings are false
  — the suite connects for real — so they are filtered with an explanation. A stale
  filter is a hard error, so the suppression expires when grpc fixes the typing.
- **Dependencies refreshed** (`mix deps.update --all`): `grpc` 1.0.1 → 1.0.2 and
  `gun` 2.2.0 → 2.4.1 — grpc 1.0.1 constrained gun to `~> 2.2.0`, and 1.0.2 relaxes it, so
  gun could finally move. Test/dev only: `cowboy` 2.14.2 → 2.17.0, `cowlib` 2.16.0 → 2.18.0,
  `finch` 0.20.0 → 0.23.0, `mint` 1.9.0 → 1.9.3, `hpax` 1.0.3 → 1.0.4, `jose` 1.11.10 →
  1.11.12, plus `erlex`, `earmark_parser`, and `makeup` patches. Full suite green on
  Elixir 1.20 / OTP 29, including the `:emulator` integration tests.

## [0.5.0] - 2026-06-26

### Changed
- **grpc 1.0 support.** Bumped `grpc` to `~> 1.0` (was `0.11.5`). grpc 1.0 is
  client-only (`GRPC.Server` was removed) and makes `:gun` optional, so `gun ~> 2.2`
  is now a direct dependency (the pool uses the default Gun adapter). `:public_key`
  and `:ssl` are declared in `extra_applications` (used by `Config`).
- **BREAKING (telemetry): the `[:grpc_connection_pool, :channel, :gun_down]` and
  `[:grpc_connection_pool, :channel, :gun_error]` events were removed.** Under
  grpc 1.0 the Gun adapter owns the socket in its own process, so those gun
  messages never reach the pool. A single adapter-agnostic
  `[:grpc_connection_pool, :channel, :connection_down]` event (metadata
  `pool_name`, `reason`) is emitted instead. `:disconnected` and
  `:reconnect_scheduled` are unchanged. Consumers handling `:gun_down`/`:gun_error`
  should switch to `:connection_down` (or `:disconnected`).
- **Disconnect detection reworked.** grpc 1.0's Gun adapter keeps the live
  connection inside its own `ConnectionProcess`, which lingers as a zombie after a
  drop, so the old `gun_down`/`gun_error` message handlers were dead code. The
  worker now monitors the inner gun process and pairs it with
  `adapter_opts: [retry: 0]` so gun fails fast on a drop and the pool's own
  `Backoff` governs reconnection. This also restores fast-fail connects (a dead
  endpoint now errors in ~0ms instead of stalling ~5s per attempt).

### Upgrade notes
- **Remove `{GRPC.Client.Supervisor, []}` from your supervision tree.** grpc 1.0 deleted
  that module; the name is now just the registered name of a `DynamicSupervisor` that
  grpc starts itself (in GRPC.Client.Application). Keeping the old child spec (which pre-1.0
  grpc's README recommended) crashes at boot with *"The module GRPC.Client.Supervisor was
  given as a child to a supervisor but it does not exist"*. Nothing replaces it — no
  manual start is needed in applications or in `test_helper.exs`. This is the only
  supervision-tree change required to move a `grpc_connection_pool` consumer from grpc
  0.11.x to 1.0.

### Fixed
- **License declaration** now correctly reports **Apache-2.0** (matching the committed
  `LICENSE` file) instead of MIT in `mix.exs` and README — resolves the Hex.pm
  mismatch (#6).

## [0.4.0] - 2026-06-01

### Changed
- **Security:** production configs now default to verifying TLS. `GrpcConnectionPool.Config.production/1`
  sets `verify: :verify_peer`, and a `:production` endpoint built without `ssl`/`credentials`
  no longer silently downgrades to plaintext h2c — it raises a clear configuration error.
- Narrowed several broad `rescue`/`catch` clauses (`Pool.scale_up/scale_down`,
  `Worker.send_ping`, `TelemetryReporter`) so unexpected errors surface instead of being
  swallowed; demoted expected reconnect/retry logs to `:debug`.

### Fixed
- Documentation: replaced README examples referencing a non-existent
  GrpcConnectionPool.execute/1 with the real `get_channel/1` + stub-call pattern;
  corrected the stale install snippet and the `:get_channel` telemetry/strategy docs.

## [0.3.5] - 2026-06-01

### Fixed
- **Slot-claim race in the hot path** — slot claim/release are now serialized through
  `PoolState` (`register_channel/3`, `unregister_channel/2`). Concurrent worker
  connects/disconnects could previously collide on a slot, leaving `:channel_count`
  higher than the populated channels so `get_channel/1` returned `:not_connected` on a
  healthy pool.
- `get_channel/1` now returns `{:error, :not_connected}` (instead of raising) when the
  pool is not started or `PoolState` is restarting.

### Changed
- **Hot-path performance:** collapsed the per-call ETS table-name rebuild + two
  `persistent_term` lookups into one combined term; `RoundRobin` uses unsigned atomics
  (no `abs/1`); `PowerOfTwo` now tracks load in lock-free `:atomics` counters
  (least-frequently-used) instead of writing a timestamp to ETS on every selection.
- Per-call `:get_channel` telemetry is configurable via `telemetry_sample_rate`
  (default `1` = emit every call; `0` disables; `N` samples ~1-in-N).
- The `pid => slot` map moved from ETS into `PoolState` state (slot claim is now O(1)).

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

## [0.2.3] - 2026-01-29

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

## [0.2.2] - 2026-01-29

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
