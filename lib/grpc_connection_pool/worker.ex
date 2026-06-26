defmodule GrpcConnectionPool.Worker do
  @moduledoc """
  GenServer-based gRPC connection worker with automatic reconnection.

  Each worker manages a single gRPC connection and stores its channel
  directly in the pool's ETS table for zero-GenServer-call access from
  `Pool.get_channel/1`.

  Features:
  - Channels stored in ETS for O(1) pool access (no GenServer.call in hot path)
  - Automatic reconnection with exponential backoff and jitter
  - Active disconnect detection by monitoring the gRPC connection process
  - Self-registration in Registry for health tracking
  - Optional periodic ping to keep connections warm
  - Configurable max reconnect attempts before crash

  ## Disconnect detection (grpc 1.0)

  grpc 1.0's Gun adapter owns the socket inside its own supervised
  `GRPC.Client.Adapters.Gun.ConnectionProcess`, so gun's `:gun_down`/`:gun_error`
  messages no longer reach this worker. Worse, when the connection drops the inner
  gun process dies but the `ConnectionProcess` (the `conn_pid` in
  `channel.adapter_payload`) lingers as a zombie — so monitoring `conn_pid` cannot
  detect a drop.

  Instead we monitor the **inner gun process**, read out of the adapter's
  `ConnectionProcess` state, and pair it with `adapter_opts: [retry: 0]` (see
  `GrpcConnectionPool.Config`) so gun gives up immediately on a drop and this
  pool's own `Backoff` governs reconnection. Reaching into the adapter state
  couples us to a grpc internal; it is guarded and falls back to monitoring
  `conn_pid` if the state shape changes.
  """
  use GenServer
  require Logger

  alias GrpcConnectionPool.{Backoff, Config, PoolState}

  defmodule State do
    @moduledoc false
    defstruct [
      :channel,
      :config,
      :ping_timer,
      :last_ping,
      :backoff_state,
      :registry_name,
      :pool_name,
      :ets_table,
      :connection_start,
      :reconnect_attempt,
      :slot_index,
      :conn_monitor_ref
    ]
  end

  # Public API

  @doc """
  Starts a connection worker.

  Options:
  - `:config` — GrpcConnectionPool.Config struct (required)
  - `:registry_name` — Registry name for self-registration (required)
  - `:pool_name` — Pool name for telemetry (required)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Gets the current connection status.
  """
  @spec status(pid()) :: :connected | :disconnected
  def status(worker) do
    GenServer.call(worker, :status)
  end

  # GenServer callbacks

  @impl GenServer
  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    registry_name = Keyword.fetch!(opts, :registry_name)
    pool_name = Keyword.fetch!(opts, :pool_name)
    ets_table = GrpcConnectionPool.Pool.ets_table_name(pool_name)

    backoff_state =
      Backoff.new(
        min: config.connection.backoff_min,
        max: config.connection.backoff_max
      )

    send(self(), :connect)

    state = %State{
      channel: nil,
      config: config,
      ping_timer: nil,
      last_ping: nil,
      backoff_state: backoff_state,
      registry_name: registry_name,
      pool_name: pool_name,
      ets_table: ets_table,
      connection_start: nil,
      reconnect_attempt: 0,
      slot_index: nil,
      conn_monitor_ref: nil
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:status, _from, %State{channel: nil} = state) do
    {:reply, :disconnected, state}
  end

  def handle_call(:status, _from, state) do
    {:reply, :connected, state}
  end

  @impl GenServer
  def handle_info(:connect, %State{} = state) do
    start_time = System.monotonic_time()

    case create_connection(state.config) do
      {:ok, channel} ->
        now = System.monotonic_time()

        Logger.debug("gRPC connection established for pool #{inspect(state.pool_name)}")

        # Monitor the connection so a drop triggers reconnection. We monitor the
        # inner gun process (which dies on drop), not the lingering conn_pid.
        conn_monitor_ref = monitor_connection(channel)

        # Register in Registry for health tracking
        Registry.register(state.registry_name, :channels, nil)

        # Register the channel via PoolState (serialized): claims a slot,
        # inserts the channel into ETS, and bumps :channel_count atomically.
        slot =
          try do
            {:ok, s} = PoolState.register_channel(state.pool_name, self(), channel)
            s
          rescue
            ArgumentError -> nil
          catch
            :exit, _ -> nil
          end

        # Emit telemetry
        :telemetry.execute(
          [:grpc_connection_pool, :channel, :connected],
          %{duration: now - start_time},
          %{pool_name: state.pool_name}
        )

        # Reset backoff on success
        new_backoff = Backoff.succeed(state.backoff_state)

        # Schedule ping if configured
        timer = schedule_ping(state.config)

        {:noreply,
         %State{
           state
           | channel: channel,
             ping_timer: timer,
             backoff_state: new_backoff,
             connection_start: now,
             reconnect_attempt: 0,
             slot_index: slot,
             conn_monitor_ref: conn_monitor_ref
         }}

      {:error, reason} ->
        now = System.monotonic_time()

        unless state.config.connection.suppress_connection_errors do
          Logger.error(
            "Failed to create gRPC connection for pool #{inspect(state.pool_name)}: #{inspect(reason)}"
          )
        end

        :telemetry.execute(
          [:grpc_connection_pool, :channel, :connection_failed],
          %{duration: now - start_time},
          %{pool_name: state.pool_name, error: reason}
        )

        new_attempt = state.reconnect_attempt + 1
        max_attempts = state.config.connection.max_reconnect_attempts

        if new_attempt >= max_attempts do
          Logger.warning(
            "Max reconnect attempts (#{max_attempts}) reached for pool #{inspect(state.pool_name)}, crashing"
          )

          {:stop, {:max_reconnect_attempts, max_attempts}, state}
        else
          {delay, new_backoff} = Backoff.fail(state.backoff_state)

          Logger.debug(
            "Retrying connection in #{delay}ms (attempt #{new_attempt}/#{max_attempts})..."
          )

          Process.send_after(self(), :connect, delay)

          {:noreply, %State{state | backoff_state: new_backoff, reconnect_attempt: new_attempt}}
        end
    end
  end

  # Handle periodic ping
  def handle_info(:ping, %State{channel: nil} = state) do
    {:noreply, state}
  end

  def handle_info(:ping, %State{channel: channel} = state) do
    start_time = System.monotonic_time()
    result = send_ping(channel)

    :telemetry.execute(
      [:grpc_connection_pool, :channel, :ping],
      %{duration: System.monotonic_time() - start_time},
      %{pool_name: state.pool_name, result: result}
    )

    case result do
      :ok ->
        timer = schedule_ping(state.config)

        {:noreply,
         %State{state | ping_timer: timer, last_ping: System.monotonic_time(:millisecond)}}

      :error ->
        Logger.warning("Ping failed for pool #{inspect(state.pool_name)}, triggering reconnect")
        handle_disconnect(state, :ping_failed)
    end
  end

  # Active disconnect detection — the monitored gRPC connection process died.
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %State{conn_monitor_ref: ref} = state
      ) do
    :telemetry.execute(
      [:grpc_connection_pool, :channel, :connection_down],
      %{},
      %{pool_name: state.pool_name, reason: reason}
    )

    unless state.config.connection.suppress_connection_errors do
      Logger.debug(
        "gRPC connection down for pool #{inspect(state.pool_name)}: #{inspect(reason)}"
      )
    end

    handle_disconnect(state, {:connection_down, reason})
  end

  # A DOWN we no longer care about (already torn down / demonitored late). Ignore.
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    remove_channel_from_ets(state)
    cleanup_connection(state)
    :ok
  end

  # Private functions

  defp create_connection(config) do
    {host, port, opts} = Config.get_endpoint(config)
    GRPC.Stub.connect("#{host}:#{port}", opts)
  end

  # The connection monitor is the primary drop detector; this ping is a warm-keep
  # plus backstop. It checks the inner gun process (the thing that actually dies on
  # a drop) rather than conn_pid, which lingers as a zombie.
  defp send_ping(%GRPC.Channel{adapter_payload: %{conn_pid: conn_pid}}) when is_pid(conn_pid) do
    if Process.alive?(conn_pid), do: gun_alive?(conn_pid), else: :error
  end

  defp send_ping(_channel), do: :error

  # Liveness of the inner gun process. If it can't be introspected we return :ok to
  # avoid false reconnects — the connection monitor (on the gun pid, set at connect)
  # is the primary drop detector; this ping is only a warm-keep + backstop.
  defp gun_alive?(conn_pid) do
    case gun_pid(conn_pid) do
      pid when is_pid(pid) -> if Process.alive?(pid), do: :ok, else: :error
      _ -> :ok
    end
  end

  defp schedule_ping(config) do
    case config.connection.ping_interval do
      nil ->
        nil

      interval when is_integer(interval) and interval > 0 ->
        Process.send_after(self(), :ping, interval)

      _ ->
        nil
    end
  end

  defp cancel_ping_timer(nil), do: :ok
  defp cancel_ping_timer(timer), do: Process.cancel_timer(timer)

  defp cleanup_connection(%State{channel: nil}), do: :ok

  defp cleanup_connection(%State{channel: channel, ping_timer: timer}) do
    cancel_ping_timer(timer)

    # GRPC.Stub.disconnect/1 is the correct teardown under grpc 1.0 — it stops the
    # adapter's ConnectionProcess (reaping the zombie left behind after a drop) and
    # is safe/idempotent on an already-dropped channel. Guarded because this is a
    # best-effort teardown path that must never crash terminate/2.
    try do
      GRPC.Stub.disconnect(channel)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  defp remove_channel_from_ets(%State{slot_index: nil}), do: :ok

  defp remove_channel_from_ets(%State{pool_name: pool_name} = state) do
    # Release the slot via PoolState (serialized): removes the channel,
    # compacts the slot array, and decrements :channel_count atomically.
    try do
      PoolState.unregister_channel(pool_name, self())
    rescue
      ArgumentError -> :ok
    catch
      :exit, _ -> :ok
    end

    # Unregister from Registry
    try do
      Registry.unregister(state.registry_name, :channels)
    rescue
      _ -> :ok
    end
  end

  # Unified disconnect handling
  defp handle_disconnect(%State{} = state, reason) do
    now = System.monotonic_time()

    # Drop the connection monitor and flush any DOWN already in the mailbox so a
    # stale DOWN can't trigger a second disconnect after we've torn down.
    demonitor_connection(state)

    # Remove channel from ETS and Registry
    remove_channel_from_ets(state)

    # Emit telemetry
    duration = if state.connection_start, do: now - state.connection_start, else: 0

    :telemetry.execute(
      [:grpc_connection_pool, :channel, :disconnected],
      %{duration: duration},
      %{pool_name: state.pool_name, reason: reason}
    )

    # Cleanup connection
    cleanup_connection(state)

    # Schedule reconnect with backoff
    {delay, new_backoff} = Backoff.fail(state.backoff_state)
    new_attempt = state.reconnect_attempt + 1

    :telemetry.execute(
      [:grpc_connection_pool, :channel, :reconnect_scheduled],
      %{delay_ms: delay, attempt: new_attempt},
      %{pool_name: state.pool_name, reason: reason}
    )

    Logger.debug(
      "Scheduling reconnection for pool #{inspect(state.pool_name)} in #{delay}ms after disconnect"
    )

    Process.send_after(self(), :connect, delay)

    {:noreply,
     %State{
       state
       | channel: nil,
         ping_timer: nil,
         backoff_state: new_backoff,
         connection_start: nil,
         reconnect_attempt: new_attempt,
         slot_index: nil,
         conn_monitor_ref: nil
     }}
  end

  # Monitors the connection so a drop triggers reconnection. grpc 1.0 keeps the live
  # gun process *inside* the Gun adapter's ConnectionProcess and never exposes it;
  # on a drop the gun process dies but ConnectionProcess lingers as a zombie, so we
  # monitor gun directly. gun also dies when its owner (conn_pid) dies, so this
  # covers conn_pid crashes too. Falls back to monitoring conn_pid if the inner gun
  # pid can't be read (grpc internal state shape changed).
  defp monitor_connection(%GRPC.Channel{adapter_payload: %{conn_pid: conn_pid}})
       when is_pid(conn_pid) do
    Process.monitor(gun_pid(conn_pid) || conn_pid)
  end

  defp monitor_connection(_channel), do: nil

  defp demonitor_connection(%State{conn_monitor_ref: nil}), do: :ok

  defp demonitor_connection(%State{conn_monitor_ref: ref}) do
    Process.demonitor(ref, [:flush])
    :ok
  end

  # Reads the inner gun pid out of the Gun adapter's ConnectionProcess state. This
  # couples us to a grpc internal (state shape %{gun_pid: pid, ...}); guarded and
  # short-timed so a busy/dead ConnectionProcess can't block or crash the worker.
  defp gun_pid(conn_pid) do
    case :sys.get_state(conn_pid, 1_000) do
      %{gun_pid: gun_pid} when is_pid(gun_pid) -> gun_pid
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end
end
