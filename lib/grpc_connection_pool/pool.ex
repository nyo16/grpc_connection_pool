defmodule GrpcConnectionPool.Pool do
  @moduledoc """
  High-performance gRPC connection pool with pluggable selection strategies.

  This module provides a DynamicSupervisor-based pool with:
  - **Zero GenServer.call hot path** — channels stored in ETS for O(1) access
  - **Pluggable strategies** — round-robin (atomics), random, power-of-two-choices
  - **`:persistent_term`** for config — zero-copy reads
  - **ETS with read/write concurrency** — optimized for concurrent access
  - **Registry** for health tracking
  - **Telemetry** with proper GenServer-based status loop

  ## Architecture

  ```
  Pool.Supervisor (one_for_one)
  ├── PoolState (GenServer — owns ETS, stores persistent_term)
  ├── Registry (health tracking)
  ├── DynamicSupervisor (manages workers)
  ├── WorkerStarter (temporary Task)
  └── TelemetryReporter (GenServer — periodic status)
  ```

  ## Hot Path

  `get_channel/1` does zero GenServer calls:

  ```
  ETS.lookup(:channel_count) → Strategy.select → ETS.lookup({:channel, idx}) → channel
  ```

  """

  use Supervisor

  alias GrpcConnectionPool.{Config, Worker, PoolState, Strategy}

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

  ## Options
  - `:name` — Pool name (overrides config name)

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
  Gets a gRPC channel from the pool.

  Zero GenServer calls — reads directly from ETS using the configured
  selection strategy (default: atomics-based round-robin).

  ## Returns
  - `{:ok, channel}` — Successfully retrieved a connected channel
  - `{:error, :not_connected}` — No healthy connections available

  ## Examples

      case GrpcConnectionPool.Pool.get_channel() do
        {:ok, channel} -> MyService.Stub.call(channel, request)
        {:error, :not_connected} -> {:error, :unavailable}
      end

  """
  @spec get_channel(atom()) :: {:ok, GRPC.Channel.t()} | {:error, :not_connected}
  def get_channel(pool_name \\ @default_pool_name) do
    ets_table = ets_table_name(pool_name)

    case :ets.lookup(ets_table, :channel_count) do
      [{:channel_count, count}] when count > 0 ->
        strategy_mod = :persistent_term.get({__MODULE__, pool_name, :strategy_mod})
        strategy_state = :persistent_term.get({__MODULE__, pool_name, :strategy_state})

        {:ok, index} = strategy_mod.select(strategy_state, count, ets_table)

        case :ets.lookup(ets_table, {:channel, index}) do
          [{{:channel, _}, channel, _last_used}] ->
            :telemetry.execute(
              [:grpc_connection_pool, :pool, :get_channel],
              %{},
              %{pool_name: pool_name, available_channels: count}
            )

            {:ok, channel}

          [] ->
            {:error, :not_connected}
        end

      _ ->
        {:error, :not_connected}
    end
  end

  @doc """
  Gets all worker PIDs in the pool.
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
  """
  @spec status(atom()) :: map()
  def status(pool_name \\ @default_pool_name) do
    try do
      ets_table = ets_table_name(pool_name)

      channel_count =
        case :ets.lookup(ets_table, :channel_count) do
          [{:channel_count, c}] -> c
          [] -> 0
        end

      expected_size =
        case :ets.lookup(ets_table, :pool_size) do
          [{:pool_size, size}] -> size
          [] -> 0
        end

      pool_status =
        cond do
          channel_count == 0 -> :down
          channel_count < expected_size -> :degraded
          true -> :healthy
        end

      %{
        pool_name: pool_name,
        expected_size: expected_size,
        current_size: channel_count,
        status: pool_status
      }
    rescue
      _ -> %{error: :pool_not_found}
    end
  end

  @doc """
  Stops a connection pool.
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

  ## Returns
  - `{:ok, new_size}` — Successfully added workers
  - `{:error, reason}` — Failed to add workers
  """
  @spec scale_up(atom(), pos_integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def scale_up(pool_name \\ @default_pool_name, count) when is_integer(count) and count > 0 do
    start_time = System.monotonic_time()
    supervisor_name = :"#{pool_name}.DynamicSupervisor"
    registry_name = registry_name(pool_name)
    ets_table = ets_table_name(pool_name)

    case acquire_scaling_lock(ets_table) do
      false ->
        {:error, :scaling_in_progress}

      true ->
        try do
          config = get_pool_config(pool_name)

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
                shutdown: 5000
              }

              DynamicSupervisor.start_child(supervisor_name, worker_spec)
            end

          successes = Enum.count(results, &match?({:ok, _}, &1))
          failures = count - successes

          new_size =
            if successes > 0 do
              update_pool_size(ets_table, successes)
            else
              get_pool_size(ets_table)
            end

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
          release_scaling_lock(ets_table)
        end
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  Dynamically remove workers from the pool.

  ## Returns
  - `{:ok, new_size}` — Successfully removed workers
  - `{:error, reason}` — Failed to remove workers
  """
  @spec scale_down(atom(), pos_integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def scale_down(pool_name \\ @default_pool_name, count) when is_integer(count) and count > 0 do
    start_time = System.monotonic_time()
    supervisor_name = :"#{pool_name}.DynamicSupervisor"
    ets_table = ets_table_name(pool_name)

    case acquire_scaling_lock(ets_table) do
      false ->
        {:error, :scaling_in_progress}

      true ->
        try do
          expected_size = get_pool_size(ets_table)

          cond do
            expected_size <= 1 ->
              {:error, :would_empty_pool}

            count >= expected_size ->
              {:error, :would_empty_pool}

            count <= 0 ->
              {:error, :invalid_count}

            true ->
              children = get_all_children(supervisor_name, count)

              if length(children) < count do
                {:error, {:insufficient_workers, length(children)}}
              else
                workers_to_stop = Enum.take(children, count)

                terminated =
                  Enum.reduce(workers_to_stop, 0, fn {_, pid, _, _}, acc ->
                    case DynamicSupervisor.terminate_child(supervisor_name, pid) do
                      :ok -> acc + 1
                      {:error, :not_found} -> acc
                    end
                  end)

                new_size =
                  if terminated > 0 do
                    update_pool_size(ets_table, -terminated)
                  else
                    expected_size
                  end

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
          release_scaling_lock(ets_table)
        end
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  Resize pool to exact size.
  """
  @spec resize(atom(), pos_integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def resize(pool_name \\ @default_pool_name, target_size)
      when is_integer(target_size) and target_size > 0 do
    ets_table = ets_table_name(pool_name)
    current_size = get_pool_size(ets_table)

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

  @doc """
  Blocks until at least one channel is connected or timeout is reached.

  Useful for application startup to ensure the pool is ready before serving traffic.

  ## Examples

      {:ok, _} = GrpcConnectionPool.Pool.start_link(config)
      :ok = GrpcConnectionPool.Pool.await_ready(MyPool, 5_000)

  """
  @spec await_ready(atom(), pos_integer()) :: :ok | {:error, :timeout}
  def await_ready(pool_name \\ @default_pool_name, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_ready(pool_name, deadline)
  end

  defp do_await_ready(pool_name, deadline) do
    ets_table = ets_table_name(pool_name)

    case :ets.lookup(ets_table, :channel_count) do
      [{:channel_count, count}] when count > 0 ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(50)
          do_await_ready(pool_name, deadline)
        end
    end
  end

  # Supervisor callbacks

  @impl Supervisor
  def init({config, pool_name}) do
    pool_size = config.pool.size
    telemetry_interval = config.pool.telemetry_interval
    registry_name = registry_name(pool_name)

    children = [
      # PoolState owns ETS + persistent_term setup (must start first)
      {PoolState, pool_name: pool_name, config: config},

      # Registry for health tracking
      {Registry, name: registry_name, keys: :duplicate},

      # DynamicSupervisor for workers
      {DynamicSupervisor, name: :"#{pool_name}.DynamicSupervisor", strategy: :one_for_one},

      # Task to start initial workers
      %{
        id: :worker_starter,
        start: {Task, :start_link, [fn -> start_workers(pool_name, config, pool_size) end]},
        restart: :temporary
      },

      # Telemetry reporter (proper GenServer, not recursive sleep)
      {GrpcConnectionPool.Pool.TelemetryReporter,
       pool_name: pool_name, expected_size: pool_size, interval: telemetry_interval}
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
        shutdown: 5000
      }

      DynamicSupervisor.start_child(supervisor_name, worker_spec)
    end
  end

  defp get_pool_name(config, opts) do
    opts[:name] ||
      Keyword.get(opts, :pool, [])[:name] ||
      config.pool.name ||
      @default_pool_name
  end

  @doc false
  def registry_name(pool_name) do
    :"#{pool_name}.Registry"
  end

  @doc false
  def ets_table_name(pool_name) do
    :"#{pool_name}.ETS"
  end

  defp get_all_children(supervisor_name, minimum_count, attempts \\ 3) do
    children = DynamicSupervisor.which_children(supervisor_name)

    if length(children) >= minimum_count or attempts <= 1 do
      children
    else
      Process.sleep(10)
      get_all_children(supervisor_name, minimum_count, attempts - 1)
    end
  end

  defp get_pool_config(pool_name) do
    :persistent_term.get({__MODULE__, pool_name, :config})
  end

  defp get_pool_size(ets_table) do
    case :ets.lookup(ets_table, :pool_size) do
      [{:pool_size, size}] -> size
      [] -> 0
    end
  end

  defp update_pool_size(ets_table, delta) do
    :ets.update_counter(ets_table, :pool_size, {2, delta}, {:pool_size, 0})
  end

  # Scaling lock with stale lock detection (30 second timeout)
  defp acquire_scaling_lock(ets_table) do
    now = System.monotonic_time(:millisecond)

    case :ets.insert_new(ets_table, {:scaling_lock, self(), now}) do
      true ->
        true

      false ->
        case :ets.lookup(ets_table, :scaling_lock) do
          [{:scaling_lock, _pid, locked_at}] when now - locked_at > 30_000 ->
            :ets.delete(ets_table, :scaling_lock)
            :ets.insert_new(ets_table, {:scaling_lock, self(), now})

          _ ->
            false
        end
    end
  end

  defp release_scaling_lock(ets_table) do
    :ets.delete(ets_table, :scaling_lock)
  end
end

defmodule GrpcConnectionPool.Pool.TelemetryReporter do
  @moduledoc false
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl GenServer
  def init(opts) do
    pool_name = Keyword.fetch!(opts, :pool_name)
    expected_size = Keyword.fetch!(opts, :expected_size)
    interval = Keyword.fetch!(opts, :interval)

    schedule(interval)

    {:ok, %{pool_name: pool_name, expected_size: expected_size, interval: interval}}
  end

  @impl GenServer
  def handle_info(:report, state) do
    ets_table = GrpcConnectionPool.Pool.ets_table_name(state.pool_name)

    current_size =
      case :ets.lookup(ets_table, :channel_count) do
        [{:channel_count, c}] -> c
        [] -> 0
      end

    :telemetry.execute(
      [:grpc_connection_pool, :pool, :status],
      %{expected_size: state.expected_size, current_size: current_size},
      %{pool_name: state.pool_name}
    )

    schedule(state.interval)
    {:noreply, state}
  rescue
    _ ->
      schedule(state.interval)
      {:noreply, state}
  end

  defp schedule(interval) do
    Process.send_after(self(), :report, interval)
  end
end
