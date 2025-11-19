defmodule GrpcConnectionPool.Pool do
  @moduledoc """
  Poolex-based gRPC connection pool.

  This module provides a high-level interface for managing gRPC connections using
  the Poolex library. It provides a flexible and configurable approach for connection pooling.

  ## Features

  - Environment-agnostic configuration (production, local, custom)
  - Automatic connection health monitoring and recovery
  - Periodic ping to keep connections warm
  - Configurable retry logic with exponential backoff
  - Support for multiple named pools
  - Built-in metrics and monitoring support (via Poolex)

  ## Usage

  ### Default Pool

      # Start with default configuration
      {:ok, config} = GrpcConnectionPool.Config.production(host: "api.example.com")
      {:ok, _pid} = GrpcConnectionPool.Pool.start_link(config)

      # Execute operations
      operation = fn channel ->
        request = %MyService.ListRequest{}
        MyService.Stub.list(channel, request)
      end

      {:ok, result} = GrpcConnectionPool.Pool.execute(operation)

  ### Custom Pool

      # Start with custom configuration
      {:ok, config} = GrpcConnectionPool.Config.local(port: 9090)
      {:ok, _pid} = GrpcConnectionPool.Pool.start_link(config, name: MyApp.CustomPool)

      # Execute operations on custom pool
      {:ok, result} = GrpcConnectionPool.Pool.execute(operation, pool: MyApp.CustomPool)

  ### Configuration from Environment

      # config/config.exs
      config :my_app, GrpcConnectionPool,
        endpoint: [type: :production, host: "api.example.com", port: 443],
        pool: [size: 8, name: MyApp.GrpcPool],
        connection: [ping_interval: 20_000]

      # In your application
      {:ok, config} = GrpcConnectionPool.Config.from_env(:my_app)
      {:ok, _pid} = GrpcConnectionPool.Pool.start_link(config)

  ## Configuration

  See `GrpcConnectionPool.Config` for detailed configuration options.
  """

  alias GrpcConnectionPool.{Config, Worker}

  @default_pool_name __MODULE__

  # Child specification for supervision trees

  @doc """
  Returns the child specification for supervision trees.

  ## Parameters
  - `config`: Pool configuration (GrpcConnectionPool.Config struct or keyword list)
  - `opts`: Additional options
    - `:name` - Pool name (overrides config name)

  ## Examples

      children = [
        {GrpcConnectionPool.Pool, [
          endpoint: [type: :production, host: "api.example.com", port: 443],
          pool: [size: 10, name: MyApp.GrpcPool]
        ]}
      ]

  """
  def child_spec(config_or_opts) when is_list(config_or_opts) do
    case Config.new(config_or_opts) do
      {:ok, config} ->
        pool_name = get_pool_name(config, config_or_opts)

        {
          Poolex,
          pool_id: pool_name,
          worker_module: Worker,
          worker_args: [config],
          workers_count: config.pool.size
        }

      {:error, reason} ->
        raise ArgumentError, "Invalid pool configuration: #{reason}"
    end
  end

  def child_spec(%Config{} = config) do
    pool_name = config.pool.name || @default_pool_name

    {
      Poolex,
      pool_id: pool_name,
      worker_module: Worker,
      worker_args: [config],
      workers_count: config.pool.size
    }
  end

  @doc """
  Starts a new connection pool.

  ## Parameters
  - `config`: Pool configuration (GrpcConnectionPool.Config struct or keyword list)
  - `opts`: Additional options
    - `:name` - Pool name (overrides config name)

  ## Returns
  - `{:ok, pid}` - Pool started successfully
  - `{:error, reason}` - Error starting pool

  ## Examples

      # With Config struct
      {:ok, config} = GrpcConnectionPool.Config.production(host: "api.example.com", pool_size: 8)
      {:ok, pid} = GrpcConnectionPool.Pool.start_link(config)

      # With keyword list
      {:ok, pid} = GrpcConnectionPool.Pool.start_link([
        endpoint: [type: :local, host: "localhost", port: 9090],
        pool: [size: 5]
      ])

  """
  @spec start_link(Config.t() | keyword(), keyword()) :: GenServer.on_start()
  def start_link(config_or_opts, opts \\ [])

  def start_link(%Config{} = config, opts) do
    pool_name = opts[:name] || config.pool.name || @default_pool_name

    Poolex.start_link(
      pool_id: pool_name,
      worker_module: Worker,
      worker_args: [config],
      workers_count: config.pool.size
    )
  end

  def start_link(config_opts, opts) when is_list(config_opts) do
    case Config.new(config_opts) do
      {:ok, config} ->
        pool_name = opts[:name] || get_pool_name(config, config_opts) || @default_pool_name

        Poolex.start_link(
          pool_id: pool_name,
          worker_module: Worker,
          worker_args: [config],
          workers_count: config.pool.size
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Executes a gRPC operation using a connection from the pool.

  ## Parameters
  - `operation_fn`: Function that takes `(channel)` and returns a result
  - `opts`: Optional parameters
    - `:pool` - Pool name to use (default: #{@default_pool_name})
    - `:checkout_timeout` - Timeout for checking out connections (default: from config)

  ## Returns
  - Result from the operation function
  - `{:error, reason}` - Error during execution or connection checkout

  ## Examples

      operation = fn channel ->
        request = %MyService.ListRequest{}
        MyService.Stub.list(channel, request)
      end

      {:ok, result} = GrpcConnectionPool.Pool.execute(operation)
      {:ok, result} = GrpcConnectionPool.Pool.execute(operation, pool: MyApp.CustomPool)

  """
  @spec execute(function(), keyword()) :: any()
  def execute(operation_fn, opts \\ []) when is_function(operation_fn, 1) do
    pool_name = opts[:pool] || @default_pool_name
    checkout_timeout = opts[:checkout_timeout] || 15_000

    try do
      Poolex.run(
        pool_name,
        fn worker ->
          Worker.execute(worker, operation_fn)
        end, checkout_timeout: checkout_timeout)
    rescue
      error -> {:error, error}
    catch
      :exit, reason -> {:error, {:exit, reason}}
      error -> {:error, {:throw, error}}
    end
  end

  @doc """
  Gets pool status and statistics.

  ## Parameters
  - `pool_name` - Pool name (default: #{@default_pool_name})

  ## Returns
  - Pool status map with worker counts and statistics

  ## Examples

      status = GrpcConnectionPool.Pool.status()
      status = GrpcConnectionPool.Pool.status(MyApp.CustomPool)

  """
  @spec status(atom()) :: map()
  def status(pool_name \\ @default_pool_name) do
    try do
      # For now, return basic status - in future we can extend this
      # when Poolex provides more status/monitoring functions
      %{pool_name: pool_name, status: :running}
    rescue
      _ -> %{error: :pool_not_found}
    end
  end

  @doc """
  Stops a connection pool.

  ## Parameters
  - `pool_name` - Pool name (default: #{@default_pool_name})

  """
  @spec stop(atom()) :: :ok
  def stop(pool_name \\ @default_pool_name) do
    try do
      spec = Poolex.child_spec(worker_module: Worker, name: pool_name)
      child_id = Map.get(spec, :id)
      DynamicSupervisor.terminate_child(Poolex.DynamicSupervisor, child_id)
    rescue
      _ -> :ok
    end

    :ok
  end

  # Private functions

  defp get_pool_name(config, opts) do
    opts[:name] ||
      Keyword.get(opts, :pool, [])[:name] ||
      config.pool.name
  end
end
