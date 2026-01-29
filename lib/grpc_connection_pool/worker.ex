defmodule GrpcConnectionPool.Worker do
  @moduledoc """
  GenServer-based gRPC connection worker with automatic reconnection and backoff.

  This worker manages a single gRPC connection with the following features:
  - Automatic connection creation with exponential backoff and jitter
  - Active disconnect detection (handles gun_down/gun_error messages)
  - Self-registration in Registry for pool health tracking
  - Optional periodic ping to keep connections warm
  - Telemetry events for observability
  - Graceful reconnection on failures

  Unlike the previous Poolex-based implementation, workers actively detect
  disconnections and trigger reconnection with backoff before crashing. This
  allows the supervisor to only handle truly fatal errors.
  """
  use GenServer
  require Logger

  alias GrpcConnectionPool.{Config, Backoff}

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
      :connection_start,
      :reconnect_attempt
    ]
  end

  # Public API

  @doc """
  Starts a connection worker with the given configuration.

  Options:
  - `:config` - GrpcConnectionPool.Config struct (required)
  - `:registry_name` - Registry name for self-registration (required)
  - `:pool_name` - Pool name for telemetry (required)
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

    backoff_state =
      Backoff.new(
        min: config.connection.backoff_min,
        max: config.connection.backoff_max
      )

    # Start connection process asynchronously
    send(self(), :connect)

    state = %State{
      channel: nil,
      config: config,
      ping_timer: nil,
      last_ping: nil,
      backoff_state: backoff_state,
      registry_name: registry_name,
      pool_name: pool_name,
      connection_start: nil,
      reconnect_attempt: 0
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

  def handle_call(:status, _from, %State{channel: _channel} = state) do
    {:reply, :connected, state}
  end

  @impl GenServer
  def handle_info(:connect, %State{} = state) do
    start_time = System.monotonic_time()

    case create_connection(state.config) do
      {:ok, channel} ->
        now = System.monotonic_time()

        Logger.debug("gRPC connection established for pool #{inspect(state.pool_name)}")

        # Register in Registry to mark as healthy
        Registry.register(state.registry_name, :channels, nil)

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
             reconnect_attempt: 0
         }}

      {:error, reason} ->
        now = System.monotonic_time()

        Logger.error(
          "Failed to create gRPC connection for pool #{inspect(state.pool_name)}: #{inspect(reason)}"
        )

        # Emit telemetry
        :telemetry.execute(
          [:grpc_connection_pool, :channel, :connection_failed],
          %{duration: now - start_time},
          %{pool_name: state.pool_name, error: reason}
        )

        # Schedule reconnect with backoff
        {delay, new_backoff} = Backoff.fail(state.backoff_state)
        Logger.info("Retrying connection in #{delay}ms...")
        Process.send_after(self(), :connect, delay)

        {:noreply, %State{state | backoff_state: new_backoff}}
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

  # Active disconnect detection - Gun adapter
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

  # Active disconnect detection - Mint adapter
  def handle_info({:elixir_grpc, :connection_down, _pid}, state) do
    Logger.debug("Mint gRPC connection down for pool #{inspect(state.pool_name)}")
    handle_disconnect(state, :mint_connection_down)
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info(:crash_after_reconnect_attempt, state) do
    # If we still don't have a connection, crash to let supervisor restart us
    if state.channel == nil do
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  @impl GenServer
  def terminate(_reason, state) do
    cleanup_connection(state)
    :ok
  end

  # Private functions

  defp create_connection(config) do
    {host, port, opts} = Config.get_endpoint(config)
    GRPC.Stub.connect("#{host}:#{port}", opts)
  end

  defp send_ping(channel) do
    try do
      # Lightweight health check - just check if process is alive
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
      # Handle the FunctionClauseError in GRPC v0.11.5 during disconnect
      case channel do
        %GRPC.Channel{adapter_payload: %{conn_pid: pid}} when is_pid(pid) ->
          # Manually close the Gun connection instead of using GRPC.Stub.disconnect
          # to avoid the pattern matching issue in GRPC.Client.Connection.handle_call
          if Process.alive?(pid) do
            :gun.close(pid)
          end

        _ ->
          # Fallback to standard disconnect for other connection types
          GRPC.Stub.disconnect(channel)
      end
    rescue
      # Catch the specific FunctionClauseError and any other errors
      FunctionClauseError -> :ok
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  # Unified disconnect handling
  defp handle_disconnect(%State{} = state, reason) do
    now = System.monotonic_time()

    # Unregister from Registry
    Registry.unregister(state.registry_name, :channels)

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

    # After attempting reconnection, we crash to let supervisor restart us
    # This is the "traditional" model where supervisor handles restarts
    Process.send_after(self(), :crash_after_reconnect_attempt, delay + 100)

    {:noreply,
     %{
       state
       | channel: nil,
         ping_timer: nil,
         backoff_state: new_backoff,
         connection_start: nil,
         reconnect_attempt: new_attempt
     }}
  end
end
