defmodule GrpcConnectionPool do
  @moduledoc """
  A flexible and robust gRPC connection pooling library for Elixir.

  This library provides efficient connection pooling for gRPC clients with
  automatic health monitoring, exponential backoff with jitter, and rich telemetry.

  ## Features

  - **Environment-agnostic**: Works with production, local, and custom gRPC endpoints
  - **Round-robin distribution**: No checkout/checkin, channels returned directly
  - **Health monitoring**: Registry-based real-time health tracking
  - **Exponential backoff with jitter**: Prevents thundering herd on reconnection
  - **Active disconnect detection**: Fast failure detection via adapter messages
  - **Multiple pools**: Support for multiple named connection pools
  - **Rich telemetry**: Comprehensive events for observability

  ## Quick Start

  ### 1. Add to dependencies

      def deps do
        [
          {:grpc_connection_pool, "~> 0.1.0"},
          {:grpc, "~> 0.10.2"}
        ]
      end

  ### 2. Start a pool

      # Production gRPC service
      {:ok, config} = GrpcConnectionPool.Config.production(
        host: "api.example.com", 
        port: 443,
        pool_size: 10
      )
      {:ok, _pid} = GrpcConnectionPool.start_link(config)

      # Local development
      {:ok, config} = GrpcConnectionPool.Config.local(port: 9090)
      {:ok, _pid} = GrpcConnectionPool.start_link(config)

  ### 3. Get a channel and use it

      case GrpcConnectionPool.get_channel() do
        {:ok, channel} ->
          request = %MyService.ListRequest{}
          MyService.Stub.list(channel, request)
        {:error, :not_connected} ->
          {:error, :unavailable}
      end

  ## Configuration

  The library supports flexible configuration through `GrpcConnectionPool.Config`:

      # From keyword list
      config = GrpcConnectionPool.Config.new([
        endpoint: [
          type: :production,
          host: "api.example.com",
          port: 443,
          ssl: []
        ],
        pool: [size: 10, name: MyApp.GrpcPool],
        connection: [ping_interval: 30_000]
      ])

      # From application environment
      # config/config.exs
      config :my_app, GrpcConnectionPool,
        endpoint: [type: :production, host: "api.example.com"],
        pool: [size: 8]

      {:ok, config} = GrpcConnectionPool.Config.from_env(:my_app)

  ## Advanced Usage

  ### Multiple Pools

      # Start multiple pools for different services
      {:ok, service_a_config} = GrpcConnectionPool.Config.production(
        host: "service-a.example.com", 
        pool_name: ServiceA.Pool
      )
      {:ok, service_b_config} = GrpcConnectionPool.Config.production(
        host: "service-b.example.com", 
        pool_name: ServiceB.Pool
      )

      children = [
        {GrpcConnectionPool, service_a_config},
        {GrpcConnectionPool, service_b_config}
      ]

      # Use specific pools
      {:ok, channel_a} = GrpcConnectionPool.get_channel(ServiceA.Pool)
      {:ok, channel_b} = GrpcConnectionPool.get_channel(ServiceB.Pool)

  ### Custom Credentials

      config = GrpcConnectionPool.Config.new([
        endpoint: [
          type: :production,
          host: "secure-api.example.com",
          port: 443,
          credentials: GRPC.Credential.new(ssl: [
            verify: :verify_peer,
            cacertfile: "/path/to/ca.pem"
          ])
        ]
      ])

  ## Testing with Emulators

  The library works great with gRPC emulators and test environments:

      # Start emulator pool for tests
      {:ok, config} = GrpcConnectionPool.Config.local(
        host: "localhost", 
        port: 8085,
        pool_size: 2
      )
      {:ok, _pid} = GrpcConnectionPool.start_link(config, name: TestPool)

      # Use in tests
      test "my grpc operation" do
        assert {:ok, channel} = GrpcConnectionPool.get_channel(TestPool)
        # Use channel for gRPC calls
      end

  """

  alias GrpcConnectionPool.Pool

  @doc """
  Starts a connection pool with the given configuration.

  This is a convenience function that delegates to `GrpcConnectionPool.Pool.start_link/2`.

  ## Examples

      {:ok, config} = GrpcConnectionPool.Config.production(host: "api.example.com")
      {:ok, pid} = GrpcConnectionPool.start_link(config)

  """
  defdelegate start_link(config, opts \\ []), to: Pool

  @doc """
  Returns a child specification for supervision trees.

  ## Examples

      children = [
        {GrpcConnectionPool, [
          endpoint: [type: :production, host: "api.example.com"],
          pool: [size: 10]
        ]}
      ]

  """
  defdelegate child_spec(config), to: Pool

  @doc """
  Gets a gRPC channel from the pool using round-robin distribution.

  Unlike traditional pools, this returns a channel directly without requiring
  checkin. The channel can be used immediately for gRPC calls.

  This is a convenience function that delegates to `GrpcConnectionPool.Pool.get_channel/1`.

  ## Examples

      case GrpcConnectionPool.get_channel() do
        {:ok, channel} ->
          request = %MyService.ListRequest{}
          MyService.Stub.list(channel, request)
        {:error, :not_connected} ->
          {:error, :unavailable}
      end

      # Use specific pool
      {:ok, channel} = GrpcConnectionPool.get_channel(MyApp.CustomPool)

  """
  defdelegate get_channel(pool_name \\ Pool), to: Pool

  @doc """
  Gets pool status and statistics.

  ## Examples

      status = GrpcConnectionPool.status()
      status = GrpcConnectionPool.status(MyApp.CustomPool)

  """
  defdelegate status(pool_name \\ Pool), to: Pool

  @doc """
  Stops a connection pool.

  ## Examples

      :ok = GrpcConnectionPool.stop()
      :ok = GrpcConnectionPool.stop(MyApp.CustomPool)

  """
  defdelegate stop(pool_name \\ Pool), to: Pool
end
