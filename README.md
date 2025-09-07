# GrpcConnectionPool

[![Hex.pm](https://img.shields.io/hexpm/v/grpc_connection_pool.svg)](https://hex.pm/packages/grpc_connection_pool)
[![Documentation](https://img.shields.io/badge/docs-hexdocs-purple.svg)](https://hexdocs.pm/grpc_connection_pool/)
[![License](https://img.shields.io/hexpm/l/grpc_connection_pool.svg)](LICENSE)

A flexible and robust gRPC connection pooling library for Elixir, providing efficient connection management with automatic health monitoring, connection warming, and environment-agnostic configuration.

## Overview

GrpcConnectionPool was extracted from a production Pub/Sub gRPC client to provide a generic, reusable solution for any Elixir application that needs reliable gRPC connection pooling. It's built on top of [Poolex](https://github.com/general-CbIC/poolex) for modern, efficient worker pool management.

### Key Features

- 🌐 **Environment-agnostic**: Works seamlessly with production, local development, and test environments
- 🔄 **Health monitoring**: Automatic connection health checks and recovery
- 🔥 **Connection warming**: Periodic pings to prevent idle connection timeouts
- 🔁 **Retry logic**: Configurable exponential backoff for connection failures
- 🏗️ **Multiple pools**: Support for multiple named pools serving different gRPC services
- ⚙️ **Flexible configuration**: Configure via code, environment variables, or config files
- 🧪 **Production tested**: Fully tested with real gRPC services including Google Pub/Sub emulator

## Why This Architecture?

### Design Decisions

We chose this architecture after learning from production experience with gRPC connection pooling:

1. **Poolex over NimblePool**: While NimblePool is excellent, Poolex offers more modern features and better monitoring capabilities that are essential for production gRPC services.

2. **GenServer Workers**: Each connection is managed by a dedicated GenServer that handles:
   - Connection lifecycle management
   - Health monitoring with periodic pings
   - Automatic reconnection with exponential backoff
   - Connection warming to prevent timeouts

3. **Environment-Agnostic Configuration**: Real applications need to work across development (local gRPC servers), testing (emulators), and production (secure cloud services) environments seamlessly.

4. **Separation of Concerns**:
   - `Config`: Pure configuration management
   - `Worker`: Connection lifecycle and health
   - `Pool`: Poolex integration and operation execution
   - `GrpcConnectionPool`: Clean public API

### Benefits Over Direct gRPC Usage

- **Reduced latency**: Pre-warmed connections eliminate cold start delays
- **Improved reliability**: Automatic reconnection and health monitoring
- **Resource efficiency**: Connection reuse and proper cleanup
- **Scalability**: Multiple pools for different services
- **Operational visibility**: Built-in monitoring and metrics

## Installation

Add `grpc_connection_pool` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:grpc_connection_pool, "~> 0.1.0"},
    {:grpc, "~> 0.10.2"}  # Required peer dependency
  ]
end
```

## Quick Start

### 1. Basic Usage

```elixir
# Create configuration
{:ok, config} = GrpcConnectionPool.Config.production(
  host: "api.example.com",
  port: 443,
  pool_size: 5
)

# Start pool
{:ok, _pid} = GrpcConnectionPool.start_link(config)

# Execute gRPC operations
operation = fn channel ->
  request = %MyService.ListRequest{}
  MyService.Stub.list(channel, request)
end

{:ok, response} = GrpcConnectionPool.execute(operation)
```

### 2. Local Development

```elixir
{:ok, config} = GrpcConnectionPool.Config.local(
  host: "localhost",
  port: 9090,
  pool_size: 3
)

{:ok, _pid} = GrpcConnectionPool.start_link(config)
```

## Configuration

### Configuration Options

The library supports flexible configuration through `GrpcConnectionPool.Config`:

```elixir
{:ok, config} = GrpcConnectionPool.Config.new([
  endpoint: [
    type: :production,           # :production, :local, or custom atom
    host: "api.example.com",     # Required: gRPC server hostname
    port: 443,                   # Required: gRPC server port  
    ssl: [],                     # SSL options ([] for default SSL)
    credentials: nil,            # Custom GRPC.Credential (overrides ssl)
    retry_config: [              # Optional: retry configuration
      max_attempts: 3,
      base_delay: 1000,
      max_delay: 5000
    ]
  ],
  pool: [
    size: 5,                     # Number of connections in pool
    name: MyApp.GrpcPool,        # Pool name (must be unique)
    checkout_timeout: 15_000     # Timeout for getting connections
  ],
  connection: [
    keepalive: 30_000,           # HTTP/2 keepalive interval
    ping_interval: 25_000,       # Ping interval to keep connections warm
    health_check: true           # Enable connection health monitoring
  ]
])
```

### Configuration from Environment

#### In `config/config.exs`:

```elixir
# Single service configuration
config :my_app, GrpcConnectionPool,
  endpoint: [
    type: :production,
    host: "api.example.com",
    port: 443,
    ssl: []
  ],
  pool: [
    size: 10,
    name: MyApp.GrpcPool
  ],
  connection: [
    ping_interval: 30_000
  ]

# Multiple service configuration
config :my_app, :service_a,
  endpoint: [type: :production, host: "service-a.example.com"],
  pool: [size: 5, name: MyApp.ServiceA.Pool]

config :my_app, :service_b, 
  endpoint: [type: :production, host: "service-b.example.com"],
  pool: [size: 8, name: MyApp.ServiceB.Pool]
```

## Complete Configuration Examples

### Basic Production Configuration

```elixir
# For a production gRPC service with SSL
config :my_app, GrpcConnectionPool,
  endpoint: [
    type: :production,
    host: "api.example.com",
    port: 443,
    ssl: []  # Use default SSL settings
  ],
  pool: [
    size: 10,
    name: MyApp.GrpcPool
  ],
  connection: [
    keepalive: 30_000,     # Send keepalive every 30 seconds
    ping_interval: 25_000,  # Ping every 25 seconds to keep warm
    health_check: true
  ]
```

### Local Development Configuration

```elixir
# For local development with a gRPC server (no SSL)
config :my_app, GrpcConnectionPool,
  endpoint: [
    type: :local,
    host: "localhost", 
    port: 9090
  ],
  pool: [
    size: 3,  # Smaller pool for development
    name: MyApp.DevPool
  ]
```

### Test Environment with Emulator

```elixir
# For testing with Google Pub/Sub emulator or similar
config :my_app, GrpcConnectionPool,
  endpoint: [
    type: :test,
    host: "localhost",
    port: 8085,
    retry_config: [
      max_attempts: 3,
      base_delay: 1000,
      max_delay: 5000
    ]
  ],
  pool: [
    size: 2,  # Small pool for tests
    name: MyApp.TestPool
  ],
  connection: [
    ping_interval: nil  # Disable pinging in tests
  ]
```

### Multiple Service Configuration

```elixir
# Configuration for multiple gRPC services
config :my_app, :service_a,
  endpoint: [
    type: :production,
    host: "service-a.example.com",
    port: 443
  ],
  pool: [
    size: 5,
    name: MyApp.ServiceAPool
  ]

config :my_app, :service_b,  
  endpoint: [
    type: :production,
    host: "service-b.example.com", 
    port: 443
  ],
  pool: [
    size: 8,
    name: MyApp.ServiceBPool
  ]
```

### Advanced SSL Configuration

```elixir
# Custom SSL configuration with client certificates
config :my_app, GrpcConnectionPool,
  endpoint: [
    type: :production,
    host: "secure-api.example.com",
    port: 443,
    credentials: GRPC.Credential.new(ssl: [
      verify: :verify_peer,
      cacertfile: "/path/to/ca.pem",
      certfile: "/path/to/client.pem", 
      keyfile: "/path/to/client-key.pem"
    ])
  ]
```

### Environment-Specific Configuration

```elixir
# Different configurations per environment using Mix.env()
case Mix.env() do
  :prod ->
    config :my_app, GrpcConnectionPool,
      endpoint: [
        type: :production,
        host: "api.example.com",
        port: 443
      ],
      pool: [size: 20]  # Large pool for production
      
  :dev ->
    config :my_app, GrpcConnectionPool,
      endpoint: [
        type: :local,
        host: "localhost", 
        port: 9090
      ],
      pool: [size: 3]   # Small pool for development
      
  :test ->
    config :my_app, GrpcConnectionPool,
      endpoint: [
        type: :test,
        host: "localhost",
        port: 8085
      ],
      pool: [size: 1],  # Minimal pool for tests
      connection: [
        ping_interval: nil  # No pinging needed in tests
      ]
end
```

#### Load from environment:

```elixir
# Single pool
{:ok, config} = GrpcConnectionPool.Config.from_env(:my_app)

# Multiple pools  
{:ok, service_a_config} = GrpcConnectionPool.Config.from_env(:my_app, :service_a)
{:ok, service_b_config} = GrpcConnectionPool.Config.from_env(:my_app, :service_b)
```

### Runtime Configuration

For configuration determined at runtime (e.g., from environment variables):

#### In `config/runtime.exs`:

```elixir
import Config

if config_env() == :prod do
  # Get configuration from environment variables
  grpc_host = System.get_env("GRPC_HOST") || "api.example.com"
  grpc_port = System.get_env("GRPC_PORT", "443") |> String.to_integer()
  pool_size = System.get_env("GRPC_POOL_SIZE", "10") |> String.to_integer()
  
  config :my_app, GrpcConnectionPool,
    endpoint: [
      type: :production,
      host: grpc_host,
      port: grpc_port
    ],
    pool: [size: pool_size]
end
```

## Adding to Supervisor Tree

### Single Pool

```elixir
defmodule MyApp.Application do
  use Application
  
  def start(_type, _args) do
    # Load configuration
    {:ok, config} = GrpcConnectionPool.Config.from_env(:my_app)
    
    children = [
      # Your other services...
      {GrpcConnectionPool, config}
    ]
    
    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

### Multiple Pools for Different Services

```elixir
defmodule MyApp.Application do
  use Application
  
  def start(_type, _args) do
    # Load configurations for different services
    {:ok, service_a_config} = GrpcConnectionPool.Config.from_env(:my_app, :service_a)
    {:ok, service_b_config} = GrpcConnectionPool.Config.from_env(:my_app, :service_b)
    
    children = [
      # Your other services...
      {GrpcConnectionPool, service_a_config},
      {GrpcConnectionPool, service_b_config}
    ]
    
    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

### Manual Pool Configuration

```elixir
def start(_type, _args) do
  # Create configurations programmatically
  {:ok, user_service_config} = GrpcConnectionPool.Config.production(
    host: "users.example.com",
    pool_name: MyApp.UserService.Pool,
    pool_size: 5
  )
  
  {:ok, payment_service_config} = GrpcConnectionPool.Config.production(
    host: "payments.example.com", 
    pool_name: MyApp.PaymentService.Pool,
    pool_size: 3
  )
  
  children = [
    {GrpcConnectionPool, user_service_config},
    {GrpcConnectionPool, payment_service_config}
  ]
  
  Supervisor.start_link(children, strategy: :one_for_one)
end
```

### Complete Application Module Examples

#### Single Pool Application

```elixir
# lib/my_app/application.ex
defmodule MyApp.Application do
  use Application
  
  def start(_type, _args) do
    # Single pool from config
    {:ok, config} = GrpcConnectionPool.Config.from_env(:my_app)
    
    children = [
      # Your other processes...
      {GrpcConnectionPool, config}
    ]
    
    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

#### Multiple Pool Application

```elixir
# lib/my_app/application.ex  
defmodule MyApp.Application do
  use Application
  
  def start(_type, _args) do
    # Load configurations for different services
    {:ok, service_a_config} = GrpcConnectionPool.Config.from_env(:my_app, :service_a)  
    {:ok, service_b_config} = GrpcConnectionPool.Config.from_env(:my_app, :service_b)
    
    children = [
      # Your other services...
      {GrpcConnectionPool, service_a_config},
      {GrpcConnectionPool, service_b_config}
    ]
    
    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

## Usage Examples

### Basic Operations

```elixir
# Simple operation with default pool
operation = fn channel ->
  request = %MyService.GetUserRequest{user_id: "123"}
  MyService.Stub.get_user(channel, request)
end

case GrpcConnectionPool.execute(operation) do
  {:ok, {:ok, user}} -> IO.puts("Found user: #{user.name}")
  {:ok, {:error, error}} -> IO.puts("gRPC error: #{inspect(error)}")
  {:error, reason} -> IO.puts("Pool error: #{inspect(reason)}")
end
```

### Using Named Pools

```elixir
# Execute on specific pool
user_operation = fn channel ->
  request = %UserService.GetRequest{id: "123"}
  UserService.Stub.get(channel, request)
end

payment_operation = fn channel ->
  request = %PaymentService.ChargeRequest{amount: 1000}
  PaymentService.Stub.charge(channel, request)
end

# Use different pools for different services
{:ok, user} = GrpcConnectionPool.execute(user_operation, pool: MyApp.UserService.Pool)
{:ok, charge} = GrpcConnectionPool.execute(payment_operation, pool: MyApp.PaymentService.Pool)
```

### Error Handling

```elixir
operation = fn channel ->
  request = %MyService.CreateRequest{data: "important data"}
  MyService.Stub.create(channel, request)
end

case GrpcConnectionPool.execute(operation) do
  {:ok, {:ok, result}} -> 
    # Success case
    handle_success(result)
    
  {:ok, {:error, %GRPC.RPCError{status: status, message: message}}} ->
    # gRPC-level error (service returned error)
    handle_grpc_error(status, message)
    
  {:error, :not_connected} ->
    # Pool has no healthy connections
    handle_connection_error()
    
  {:error, {:exit, {:noproc, _}}} ->
    # Pool doesn't exist
    handle_pool_missing_error()
    
  {:error, reason} ->
    # Other pool-level errors
    handle_pool_error(reason)
end
```

### Custom SSL Configuration

```elixir
# For services requiring client certificates
ssl_config = [
  verify: :verify_peer,
  cacertfile: "/path/to/ca.pem",
  certfile: "/path/to/client.pem", 
  keyfile: "/path/to/client-key.pem"
]

{:ok, config} = GrpcConnectionPool.Config.new([
  endpoint: [
    type: :production,
    host: "secure-api.example.com",
    port: 443,
    ssl: ssl_config
  ],
  pool: [size: 5]
])
```

### Using Custom gRPC Credentials

```elixir
# For advanced authentication scenarios
credentials = GRPC.Credential.new(ssl: [
  verify: :verify_peer,
  cacerts: :public_key.cacerts_get()
])

{:ok, config} = GrpcConnectionPool.Config.new([
  endpoint: [
    type: :production,
    host: "api.example.com", 
    port: 443,
    credentials: credentials  # Overrides ssl config
  ]
])
```

## Environment-Specific Usage

### Development Environment

```elixir
# config/dev.exs
config :my_app, GrpcConnectionPool,
  endpoint: [
    type: :local,
    host: "localhost",
    port: 9090  # Local gRPC server
  ],
  pool: [size: 2],  # Smaller pool for development
  connection: [
    ping_interval: nil  # Disable pinging for local development
  ]
```

### Test Environment with Emulators

```elixir
# config/test.exs
config :my_app, GrpcConnectionPool,
  endpoint: [
    type: :test,
    host: "localhost",
    port: 8085,  # Emulator port
    retry_config: [
      max_attempts: 3,
      base_delay: 500,   # Faster retries for tests
      max_delay: 2000
    ]
  ],
  pool: [size: 1],  # Minimal pool for tests
  connection: [
    ping_interval: nil,  # No pinging needed in tests
    health_check: false  # Disable health checks in tests
  ]
```

### Production Environment

```elixir
# config/prod.exs  
config :my_app, GrpcConnectionPool,
  endpoint: [
    type: :production,
    host: "api.example.com",
    port: 443,
    ssl: []  # Use default SSL
  ],
  pool: [
    size: 20,  # Large pool for production load
    checkout_timeout: 10_000
  ],
  connection: [
    keepalive: 30_000,
    ping_interval: 25_000,
    health_check: true
  ]
```

## Advanced Features

### Pool Monitoring

```elixir
# Check pool status
status = GrpcConnectionPool.status()
IO.inspect(status)  # %{pool_name: GrpcConnectionPool.Pool, status: :running}

# Check specific pool
status = GrpcConnectionPool.status(MyApp.UserService.Pool)
```

### Graceful Shutdown

```elixir
# Stop specific pool
:ok = GrpcConnectionPool.stop(MyApp.UserService.Pool)

# The pool will be automatically restarted by the supervisor if needed
```

### Connection Health

The library automatically monitors connection health and replaces dead connections. You can also check worker status:

```elixir
# This is mainly for debugging - not needed in normal usage
worker_pid = :poolex.checkout(MyApp.UserService.Pool)
status = GrpcConnectionPool.Worker.status(worker_pid)  # :connected | :disconnected
:poolex.checkin(MyApp.UserService.Pool, worker_pid)
```

## Testing

### Unit Tests

```bash
mix test --exclude emulator
```

### Integration Tests with Emulator

Start the Google Pub/Sub emulator (or any gRPC service emulator):

```bash
# Using Docker Compose (if available)
docker-compose up -d

# Or manually
docker run --rm -p 8085:8085 google/cloud-sdk:emulators-pubsub \
  /google-cloud-sdk/bin/gcloud beta emulators pubsub start \
  --host-port=0.0.0.0:8085 --project=test-project
```

Run integration tests:

```bash
mix test --only emulator
```

Run all tests:

```bash
mix test
```

### Testing in Your Application

```elixir
# In your test helper
defmodule MyApp.TestHelper do
  def start_test_pool do
    {:ok, config} = GrpcConnectionPool.Config.local(
      host: "localhost",
      port: 8085,  # Your test service port
      pool_size: 1
    )
    
    {:ok, _pid} = GrpcConnectionPool.start_link(config, name: TestPool)
  end
  
  def stop_test_pool do
    GrpcConnectionPool.stop(TestPool)
  end
end

# In your tests
defmodule MyApp.GrpcTest do
  use ExUnit.Case
  
  setup do
    MyApp.TestHelper.start_test_pool()
    on_exit(&MyApp.TestHelper.stop_test_pool/0)
  end
  
  test "grpc operation works" do
    operation = fn channel ->
      # Your gRPC test operation
    end
    
    assert {:ok, result} = GrpcConnectionPool.execute(operation, pool: TestPool)
  end
end
```

## Performance Considerations

### Pool Sizing

- **Small services**: 3-5 connections per pool
- **Medium load**: 5-10 connections per pool  
- **High load**: 10-20+ connections per pool
- **Multiple services**: Separate pools with appropriate sizing

### Connection Settings

```elixir
config :my_app, GrpcConnectionPool,
  connection: [
    keepalive: 30_000,     # Keep connections alive (important for cloud services)
    ping_interval: 25_000, # Ping before cloud timeouts (usually 60s)
    health_check: true     # Enable automatic health monitoring
  ]
```

### Monitoring

Monitor pool performance using:
- Connection establishment logs
- Pool checkout timeouts
- gRPC operation latencies
- Connection health check failures

## Troubleshooting

### Common Issues

1. **`:noproc` errors**: Pool not started or wrong pool name
2. **Connection timeouts**: Network issues or service unavailable
3. **SSL errors**: Incorrect SSL configuration or certificates
4. **Pool checkout timeouts**: Pool too small or slow operations

### Debug Logging

Enable debug logging to troubleshoot issues:

```elixir
# config/config.exs
config :logger, level: :info

# In your code
require Logger
Logger.info("Pool status: #{inspect(GrpcConnectionPool.status())}")
```

### Health Check Failures

If you see frequent reconnections:

1. Check network connectivity
2. Verify service availability
3. Adjust `ping_interval` and `keepalive` settings
4. Check for firewall or load balancer timeouts

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Make your changes
4. Add tests for your changes
5. Run the test suite (`mix test`)
6. Commit your changes (`git commit -m 'Add amazing feature'`)
7. Push to the branch (`git push origin feature/amazing-feature`)
8. Open a Pull Request

### Development Setup

```bash
git clone https://github.com/nyo16/grpc_connection_pool.git
cd grpc_connection_pool
mix deps.get
mix test
```

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Built on top of [Poolex](https://github.com/general-CbIC/poolex) for excellent pool management
- Inspired by production requirements from Google Cloud Pub/Sub integration
- Thanks to the Elixir gRPC community for the solid foundation

---

**Documentation**: [https://hexdocs.pm/grpc_connection_pool](https://hexdocs.pm/grpc_connection_pool)  
**Source Code**: [https://github.com/nyo16/grpc_connection_pool](https://github.com/nyo16/grpc_connection_pool)  
**Issues**: [https://github.com/nyo16/grpc_connection_pool/issues](https://github.com/nyo16/grpc_connection_pool/issues)

