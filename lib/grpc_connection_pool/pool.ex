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

  @doc """
  Dynamically add workers to the pool.

  ## Parameters
  - `pool_name`: Pool name (default: #{@default_pool_name})
  - `count`: Number of workers to add

  ## Returns
  - `{:ok, new_size}` - Successfully added workers
  - `{:error, reason}` - Failed to add workers

  ## Examples

      {:ok, 10} = GrpcConnectionPool.Pool.scale_up(MyApp.Pool, 5)
  """
  @spec scale_up(atom(), pos_integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def scale_up(pool_name \\ @default_pool_name, count) when is_integer(count) and count > 0 do
    start_time = System.monotonic_time()
    supervisor_name = :"#{pool_name}.DynamicSupervisor"
    registry_name = registry_name(pool_name)

    # Acquire lock to prevent concurrent scaling operations
    ets_table = ets_table_name(pool_name)
    lock_key = :scaling_lock

    case :ets.insert_new(ets_table, {lock_key, self()}) do
      false ->
        {:error, :scaling_in_progress}

      true ->
        try do
          config = get_pool_config(pool_name)

          # Start new workers
          results =
            for _i <- 1..count do
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
                restart: :permanent,
                # Allow 5 seconds for graceful shutdown
                shutdown: 5000
              }

              DynamicSupervisor.start_child(supervisor_name, worker_spec)
            end

          # Count successes and failures
          successes = Enum.count(results, &match?({:ok, _}, &1))
          failures = count - successes

          # Update pool size by actual number of workers added
          new_size =
            if successes > 0 do
              update_pool_size(pool_name, successes)
            else
              get_pool_size(ets_table)
            end

          # Emit telemetry
          :telemetry.execute(
            [:grpc_connection_pool, :pool, :scale_up],
            %{
              duration: System.monotonic_time() - start_time,
              requested: count,
              succeeded: successes,
              failed: failures,
              new_size: new_size
            },
            %{pool_name: pool_name}
          )

          if failures > 0 do
            {:error, {:partial_failure, failures, new_size}}
          else
            {:ok, new_size}
          end
        after
          :ets.delete(ets_table, lock_key)
        end
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  Dynamically remove workers from the pool.

  ## Parameters
  - `pool_name`: Pool name (default: #{@default_pool_name})
  - `count`: Number of workers to remove

  ## Returns
  - `{:ok, new_size}` - Successfully removed workers
  - `{:error, reason}` - Failed to remove workers

  ## Examples

      {:ok, 5} = GrpcConnectionPool.Pool.scale_down(MyApp.Pool, 2)
  """
  @spec scale_down(atom(), pos_integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def scale_down(pool_name \\ @default_pool_name, count) when is_integer(count) and count > 0 do
    start_time = System.monotonic_time()
    supervisor_name = :"#{pool_name}.DynamicSupervisor"
    ets_table = ets_table_name(pool_name)
    lock_key = :scaling_lock

    case :ets.insert_new(ets_table, {lock_key, self()}) do
      false ->
        {:error, :scaling_in_progress}

      true ->
        try do
          # Get expected size from ETS
          expected_size = get_pool_size(ets_table)

          cond do
            expected_size <= 1 ->
              {:error, :would_empty_pool}

            count >= expected_size ->
              {:error, :would_empty_pool}

            count <= 0 ->
              {:error, :invalid_count}

            true ->
              # Get all children from DynamicSupervisor
              # Retry a few times to ensure we get all workers
              children = get_all_children(supervisor_name, count)

              if length(children) < count do
                # Not enough workers available to terminate
                {:error, {:insufficient_workers, length(children)}}
              else
                workers_to_stop = Enum.take(children, count)

                # Terminate the requested number of workers
                terminated =
                  Enum.reduce(workers_to_stop, 0, fn {_, pid, _, _}, acc ->
                    case DynamicSupervisor.terminate_child(supervisor_name, pid) do
                      :ok -> acc + 1
                      {:error, :not_found} -> acc
                    end
                  end)

                # Update ETS pool_size by actual number terminated
                new_size =
                  if terminated > 0 do
                    update_pool_size(pool_name, -terminated)
                  else
                    expected_size
                  end

                # Reset round-robin index to avoid pointing to non-existent workers
                :ets.insert(ets_table, {:index, -1})

                # Emit telemetry
                :telemetry.execute(
                  [:grpc_connection_pool, :pool, :scale_down],
                  %{
                    duration: System.monotonic_time() - start_time,
                    requested: count,
                    terminated: terminated,
                    new_size: new_size
                  },
                  %{pool_name: pool_name}
                )

                if terminated == count do
                  {:ok, new_size}
                else
                  {:error, {:partial_termination, terminated, new_size}}
                end
              end
          end
        after
          :ets.delete(ets_table, lock_key)
        end
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  Resize pool to exact size.

  ## Parameters
  - `pool_name`: Pool name (default: #{@default_pool_name})
  - `target_size`: Desired pool size

  ## Returns
  - `{:ok, new_size}` - Successfully resized
  - `{:error, reason}` - Failed to resize

  ## Examples

      {:ok, 10} = GrpcConnectionPool.Pool.resize(MyApp.Pool, 10)
  """
  @spec resize(atom(), pos_integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def resize(pool_name \\ @default_pool_name, target_size)
      when is_integer(target_size) and target_size > 0 do
    ets_table = ets_table_name(pool_name)

    # Get expected size from ETS
    current_size =
      case :ets.lookup(ets_table, :pool_size) do
        [{:pool_size, size}] -> size
        [] -> 0
      end

    cond do
      target_size > current_size ->
        scale_up(pool_name, target_size - current_size)

      target_size < current_size ->
        scale_down(pool_name, current_size - target_size)

      true ->
        {:ok, current_size}
    end
  rescue
    e -> {:error, e}
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
    :ets.insert(ets_table, {:config, config})

    children = [
      # Registry for tracking connected channels
      {Registry, name: registry_name, keys: :duplicate},

      # DynamicSupervisor for workers
      {DynamicSupervisor, name: :"#{pool_name}.DynamicSupervisor", strategy: :one_for_one},

      # Task to start workers
      %{
        id: :worker_starter,
        start: {Task, :start_link, [fn -> start_workers(pool_name, config, pool_size) end]},
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

    {host, port, _opts} = Config.get_endpoint(config)

    :telemetry.execute(
      [:grpc_connection_pool, :pool, :init],
      %{pool_size: pool_size},
      %{pool_name: pool_name, endpoint: "#{host}:#{port}"}
    )

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
        restart: :permanent,
        # Allow 5 seconds for graceful shutdown
        shutdown: 5000
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

  # Helper function to get all children from DynamicSupervisor
  # Retries a few times with small delays to handle race conditions
  defp get_all_children(supervisor_name, minimum_count, attempts \\ 3) do
    children = DynamicSupervisor.which_children(supervisor_name)

    if length(children) >= minimum_count or attempts <= 1 do
      children
    else
      Process.sleep(10)
      get_all_children(supervisor_name, minimum_count, attempts - 1)
    end
  end

  # Helper function to get pool config from ETS
  defp get_pool_config(pool_name) do
    ets_table = ets_table_name(pool_name)

    case :ets.lookup(ets_table, :config) do
      [{:config, config}] -> config
      [] -> raise "Pool config not found for #{pool_name}"
    end
  end

  # Helper function to get pool size from ETS
  defp get_pool_size(ets_table) do
    case :ets.lookup(ets_table, :pool_size) do
      [{:pool_size, size}] -> size
      [] -> 0
    end
  end

  # Helper function to update pool size in ETS
  defp update_pool_size(pool_name, delta) do
    ets_table = ets_table_name(pool_name)

    :ets.update_counter(ets_table, :pool_size, {2, delta}, {:pool_size, 0})
  end
end
