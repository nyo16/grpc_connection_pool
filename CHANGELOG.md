# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
