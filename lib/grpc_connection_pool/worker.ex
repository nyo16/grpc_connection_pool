defmodule GrpcConnectionPool.Worker do
  @moduledoc """
  GenServer-based gRPC connection worker with automatic reconnection.

  Each worker manages a single gRPC connection and stores its channel
  directly in the pool's ETS table for zero-GenServer-call access from
  `Pool.get_channel/1`.

  Features:
  - Channels stored in ETS for O(1) pool access (no GenServer.call in hot path)
  - Automatic reconnection with exponential backoff and jitter
  - Active disconnect detection (gun_down/gun_error messages)
  - Self-registration in Registry for health tracking
  - Optional periodic ping to keep connections warm
  - Configurable max reconnect attempts before crash
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
      :slot_index
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
  Gets the current gRPC channel if connected.
  """
  @spec get_channel(pid()) :: {:ok, GRPC.Channel.t()} | {:error, :not_connected}
  def get_channel(worker) do
    GenServer.call(worker, :get_channel)
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
      slot_index: nil
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:get_channel, _from, %State{channel: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(:get_channel, _from, %State{channel: channel} = state) do
    {:reply, {:ok, channel}, state}
  end

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

        # Register in Registry for health tracking
        Registry.register(state.registry_name, :channels, nil)

        # Store channel in ETS for zero-GenServer-call access
        slot =
          try do
            s = PoolState.claim_slot(state.ets_table, self())
            :ets.insert(state.ets_table, {{:channel, s}, channel, now})
            :ets.update_counter(state.ets_table, :channel_count, {2, 1}, {:channel_count, 0})
            s
          rescue
            ArgumentError -> nil
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
             slot_index: slot
         }}

      {:error, reason} ->
        now = System.monotonic_time()

        Logger.error(
          "Failed to create gRPC connection for pool #{inspect(state.pool_name)}: #{inspect(reason)}"
        )

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

          Logger.info(
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

  # Active disconnect detection — Gun adapter
  def handle_info({:gun_down, _conn_pid, protocol, reason, _killed_streams}, state) do
    :telemetry.execute(
      [:grpc_connection_pool, :channel, :gun_down],
      %{},
      %{pool_name: state.pool_name, reason: reason, protocol: protocol}
    )

    unless state.config.connection.suppress_connection_errors do
      Logger.debug(
        "gRPC connection closed by server for pool #{inspect(state.pool_name)}: #{inspect(reason)}"
      )
    end

    handle_disconnect(state, {:gun_down, reason})
  end

  def handle_info({:gun_error, _conn_pid, reason}, state) do
    :telemetry.execute(
      [:grpc_connection_pool, :channel, :gun_error],
      %{},
      %{pool_name: state.pool_name, reason: reason}
    )

    unless state.config.connection.suppress_connection_errors do
      Logger.error(
        "Gun connection error for pool #{inspect(state.pool_name)}: #{inspect(reason)}"
      )
    end

    handle_disconnect(state, {:gun_error, reason})
  end

  def handle_info({:gun_up, _conn_pid, _protocol}, state) do
    Logger.debug("Gun connection is up for pool #{inspect(state.pool_name)}")
    {:noreply, state}
  end

  # Active disconnect detection — Mint adapter
  def handle_info({:elixir_grpc, :connection_down, _pid}, state) do
    Logger.debug("Mint gRPC connection down for pool #{inspect(state.pool_name)}")
    handle_disconnect(state, :mint_connection_down)
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

  defp send_ping(channel) do
    case channel do
      %GRPC.Channel{adapter_payload: %{conn_pid: pid}} when is_pid(pid) ->
        if Process.alive?(pid), do: :ok, else: :error

      _ ->
        :error
    end
  rescue
    _ -> :error
  catch
    _ -> :error
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

    try do
      case channel do
        %GRPC.Channel{adapter_payload: %{conn_pid: pid}} when is_pid(pid) ->
          if Process.alive?(pid) do
            :gun.close(pid)
          end

        _ ->
          GRPC.Stub.disconnect(channel)
      end
    rescue
      FunctionClauseError -> :ok
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  defp remove_channel_from_ets(%State{slot_index: nil}), do: :ok

  defp remove_channel_from_ets(%State{ets_table: ets_table} = state) do
    try do
      PoolState.release_slot(ets_table, self())
      :ets.update_counter(ets_table, :channel_count, {2, -1, 0, 0})
    rescue
      _ -> :ok
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

    Logger.info(
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
         slot_index: nil
     }}
  end
end
