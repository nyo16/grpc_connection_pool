defmodule GrpcConnectionPool.Pool do
  @moduledoc """
  DynamicSupervisor-based gRPC connection pool with round-robin distribution.

  This module provides a high-level interface for managing gRPC connections using
  a DynamicSupervisor with Registry-based health tracking. Unlike the previous
  Poolex implementation, this uses a "no checkout" model where channels are
  returned directly via round-robin selection.

  ## Architecture

  The pool consists of:
  - DynamicSupervisor managing worker processes
  - Registry for tracking healthy connections
  - ETS table for round-robin counter
  - Telemetry task for periodic health reporting

  ## Features

  - Round-robin channel distribution (no checkout/checkin)
  - Real-time health tracking via Registry
  - Automatic worker restart on crashes
  - Exponential backoff with jitter for reconnections
  - Rich telemetry events
  - Periodic pool status reporting

  ## Usage

      # Start pool
      {:ok, config} = GrpcConnectionPool.Config.production(host: "api.example.com")
      {:ok, _pid} = GrpcConnectionPool.Pool.start_link(config)

      # Get a channel (no checkout needed)
      case GrpcConnectionPool.Pool.get_channel() do
        {:ok, channel} ->
          # Use channel for gRPC calls
          MyService.Stub.call(channel, request)
        {:error, :not_connected} ->
          # No healthy connections available
      end

  """

  use Supervisor

  alias GrpcConnectionPool.{Config, Worker}

  @default_pool_name __MODULE__

  # Child specification for supervision trees

  @doc """
  Returns the child specification for supervision trees.
  """
  def child_spec(config_or_opts) when is_list(config_or_opts) do
    case Config.new(config_or_opts) do
      {:ok, config} ->
        pool_name = get_pool_name(config, config_or_opts)

        %{
          id: pool_name,
          start: {__MODULE__, :start_link, [config, [name: pool_name]]},
          type: :supervisor
        }

      {:error, reason} ->
        raise ArgumentError, "Invalid pool configuration: #{reason}"
    end
  end

  def child_spec(%Config{} = config) do
    pool_name = config.pool.name || @default_pool_name

    %{
      id: pool_name,
      start: {__MODULE__, :start_link, [config, [name: pool_name]]},
      type: :supervisor
    }
  end

  @doc """
  Starts a new connection pool.

  ## Parameters
  - `config`: Pool configuration (GrpcConnectionPool.Config struct or keyword list)
  - `opts`: Additional options
    - `:name` - Pool name (overrides config name)

  ## Examples

      {:ok, config} = GrpcConnectionPool.Config.production(host: "api.example.com", pool_size: 8)
      {:ok, pid} = GrpcConnectionPool.Pool.start_link(config)

  """
  @spec start_link(Config.t() | keyword(), keyword()) :: Supervisor.on_start()
  def start_link(config_or_opts, opts \\ [])

  def start_link(%Config{} = config, opts) do
    pool_name = opts[:name] || config.pool.name || @default_pool_name
    Supervisor.start_link(__MODULE__, {config, pool_name}, name: :"#{pool_name}.Supervisor")
  end

  def start_link(config_opts, opts) when is_list(config_opts) do
    case Config.new(config_opts) do
      {:ok, config} ->
        pool_name = opts[:name] || get_pool_name(config, config_opts) || @default_pool_name
        Supervisor.start_link(__MODULE__, {config, pool_name}, name: :"#{pool_name}.Supervisor")

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Gets a gRPC channel from the pool using round-robin distribution.

  Unlike traditional pool checkout, this returns a channel directly without
  requiring checkin. The channel can be used immediately for gRPC calls.

  ## Parameters
  - `pool_name`: Pool name (default: #{@default_pool_name})

  ## Returns
  - `{:ok, channel}` - Successfully retrieved a connected channel
  - `{:error, :not_connected}` - No healthy connections available

  ## Examples

      case GrpcConnectionPool.Pool.get_channel() do
        {:ok, channel} -> MyService.Stub.call(channel, request)
        {:error, :not_connected} -> {:error, :unavailable}
      end

      {:ok, channel} = GrpcConnectionPool.Pool.get_channel(MyApp.CustomPool)

  """
  @spec get_channel(atom()) :: {:ok, GRPC.Channel.t()} | {:error, :not_connected}
  def get_channel(pool_name \\ @default_pool_name) do
    start_time = System.monotonic_time()
    registry_name = registry_name(pool_name)

    channels = Registry.lookup(registry_name, :channels)
    pool_size = length(channels)

    result =
      if pool_size > 0 do
        do_get_channel(pool_name, channels, pool_size)
      else
        {:error, :not_connected}
      end

    # Emit telemetry
    :telemetry.execute(
      [:grpc_connection_pool, :pool, :get_channel],
      %{duration: System.monotonic_time() - start_time},
      %{pool_name: pool_name, available_channels: pool_size}
    )

    result
  end

  @doc """
  Gets all worker PIDs in the pool.

  ## Parameters
  - `pool_name`: Pool name (default: #{@default_pool_name})

  ## Returns
  List of worker PIDs (includes both connected and disconnected workers)

  """
  @spec get_all_pids(atom()) :: [pid()]
  def get_all_pids(pool_name \\ @default_pool_name) do
    registry_name = registry_name(pool_name)

    registry_name
    |> Registry.lookup(:channels)
    |> Enum.map(fn {pid, _} -> pid end)
  end

  @doc """
  Gets pool status and statistics.

  ## Parameters
  - `pool_name`: Pool name (default: #{@default_pool_name})

  ## Returns
  Map with pool status including:
  - `:pool_name` - Name of the pool
  - `:expected_size` - Configured pool size
  - `:current_size` - Number of currently connected channels
  - `:status` - Overall status (`:healthy`, `:degraded`, or `:down`)

  """
  @spec status(atom()) :: map()
  def status(pool_name \\ @default_pool_name) do
    try do
      registry_name = registry_name(pool_name)
      channels = Registry.lookup(registry_name, :channels)
      current_size = length(channels)

      # Get expected size from ETS
      ets_table = ets_table_name(pool_name)
      expected_size =
        case :ets.lookup(ets_table, :pool_size) do
          [{:pool_size, size}] -> size
          [] -> 0
        end

      pool_status =
        cond do
          current_size == 0 -> :down
          current_size < expected_size -> :degraded
          true -> :healthy
        end

      %{
        pool_name: pool_name,
        expected_size: expected_size,
        current_size: current_size,
        status: pool_status
      }
    rescue
      _ -> %{error: :pool_not_found}
    end
  end

  @doc """
  Stops a connection pool.

  ## Parameters
  - `pool_name`: Pool name (default: #{@default_pool_name})

  """
  @spec stop(atom()) :: :ok
  def stop(pool_name \\ @default_pool_name) do
    supervisor_name = :"#{pool_name}.Supervisor"

    try do
      case Process.whereis(supervisor_name) do
        nil ->
          :ok

        pid ->
          ref = Process.monitor(pid)
          Supervisor.stop(supervisor_name, :normal, 5000)

          receive do
            {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
          after
            5000 -> :ok
          end
      end
    catch
      :exit, {:noproc, _} -> :ok
      :exit, {:normal, _} -> :ok
      :exit, {:shutdown, _} -> :ok
    end

    :ok
  end

  # Supervisor callbacks

  @impl Supervisor
  def init({config, pool_name}) do
    pool_size = config.pool.size
    telemetry_interval = config.pool.telemetry_interval
    registry_name = registry_name(pool_name)
    ets_table = ets_table_name(pool_name)

    # Create ETS table for round-robin counter and metadata
    :ets.new(ets_table, [:public, :named_table, :set])
    :ets.insert(ets_table, {:index, -1})
    :ets.insert(ets_table, {:pool_size, pool_size})

    children = [
      # Registry for tracking connected channels
      {Registry, name: registry_name, keys: :duplicate},

      # DynamicSupervisor for workers
      {DynamicSupervisor,
       name: :"#{pool_name}.DynamicSupervisor", strategy: :one_for_one},

      # Task to start workers
      %{
        id: :worker_starter,
        start:
          {Task, :start_link,
           [fn -> start_workers(pool_name, config, pool_size) end]},
        restart: :temporary
      },

      # Telemetry status loop
      %{
        id: :telemetry_status_loop,
        start:
          {Task, :start_link,
           [fn -> telemetry_status_loop(pool_name, pool_size, telemetry_interval) end]},
        restart: :permanent
      }
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Private functions

  defp do_get_channel(pool_name, channels, pool_size) do
    ets_table = ets_table_name(pool_name)

    # Atomic round-robin counter with wrap-around
    index =
      :ets.update_counter(
        ets_table,
        :index,
        {2, 1, pool_size - 1, 0}
      )

    {pid, _} = Enum.at(channels, index)

    # Get channel from worker
    Worker.get_channel(pid)
  end

  defp start_workers(pool_name, config, pool_size) do
    supervisor_name = :"#{pool_name}.DynamicSupervisor"
    registry_name = registry_name(pool_name)

    for _i <- 1..pool_size do
      worker_spec = %{
        id: Worker,
        start:
          {Worker, :start_link,
           [
             [
               config: config,
               registry_name: registry_name,
               pool_name: pool_name
             ]
           ]},
        restart: :permanent
      }

      DynamicSupervisor.start_child(supervisor_name, worker_spec)
    end
  end

  defp telemetry_status_loop(pool_name, expected_size, interval) do
    registry_name = registry_name(pool_name)
    current_size = registry_name |> Registry.lookup(:channels) |> length()

    :telemetry.execute(
      [:grpc_connection_pool, :pool, :status],
      %{expected_size: expected_size, current_size: current_size},
      %{pool_name: pool_name}
    )

    :timer.sleep(interval)
    telemetry_status_loop(pool_name, expected_size, interval)
  end

  defp get_pool_name(config, opts) do
    opts[:name] ||
      Keyword.get(opts, :pool, [])[:name] ||
      config.pool.name ||
      @default_pool_name
  end

  defp registry_name(pool_name) do
    :"#{pool_name}.Registry"
  end

  defp ets_table_name(pool_name) do
    :"#{pool_name}.ETS"
  end
end
