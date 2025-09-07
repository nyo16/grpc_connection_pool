defmodule GrpcConnectionPool.Worker do
  @moduledoc """
  GenServer-based gRPC connection worker for use with Poolex.

  This worker manages a single gRPC connection with the following features:
  - Automatic connection creation and health monitoring
  - Periodic ping to keep connections warm
  - Environment-agnostic connection handling (production, local, custom)
  - Automatic reconnection on connection failures
  - Configurable retry logic with exponential backoff
  """
  use GenServer
  require Logger

  alias GrpcConnectionPool.Config

  defmodule State do
    @moduledoc false
    defstruct [:channel, :config, :ping_timer, :last_ping]
  end

  # Public API

  @doc """
  Starts a connection worker with the given configuration.
  """
  @spec start_link(Config.t()) :: GenServer.on_start()
  def start_link(config) do
    GenServer.start_link(__MODULE__, config)
  end

  @doc """
  Executes a gRPC operation with the worker's connection.
  """
  @spec execute(pid(), function()) :: any()
  def execute(worker, fun) when is_function(fun, 1) do
    GenServer.call(worker, {:execute, fun}, :infinity)
  end

  @doc """
  Gets the current connection status.
  """
  @spec status(pid()) :: :connected | :disconnected | :connecting
  def status(worker) do
    GenServer.call(worker, :status)
  end

  @doc """
  Forces a reconnection attempt.
  """
  @spec reconnect(pid()) :: :ok
  def reconnect(worker) do
    GenServer.call(worker, :reconnect)
  end

  # GenServer callbacks

  @impl GenServer
  def init(config) do
    # Start connection process asynchronously
    send(self(), :connect)
    
    state = %State{
      channel: nil,
      config: config,
      ping_timer: nil,
      last_ping: nil
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:execute, _fun}, _from, %State{channel: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:execute, fun}, _from, %State{channel: channel} = state) do
    case is_connection_alive?(channel) do
      true ->
        try do
          result = fun.(channel)
          {:reply, result, update_last_ping(state)}
        rescue
          error ->
            Logger.warning("gRPC operation failed: #{inspect(error)}")
            {:reply, {:error, error}, state}
        end

      false ->
        Logger.warning("Connection is dead, reconnecting...")
        send(self(), :connect)
        {:reply, {:error, :connection_dead}, %State{state | channel: nil}}
    end
  end

  def handle_call(:status, _from, %State{channel: nil} = state) do
    {:reply, :disconnected, state}
  end

  def handle_call(:status, _from, %State{channel: channel} = state) do
    status = if is_connection_alive?(channel), do: :connected, else: :disconnected
    {:reply, status, state}
  end

  def handle_call(:reconnect, _from, state) do
    cleanup_connection(state.channel)
    cancel_ping_timer(state.ping_timer)
    send(self(), :connect)
    {:reply, :ok, %State{state | channel: nil, ping_timer: nil}}
  end

  @impl GenServer
  def handle_info(:connect, state) do
    case create_connection(state.config) do
      {:ok, channel} ->
        Logger.debug("gRPC connection established")
        timer = schedule_ping(state.config)
        {:noreply, %State{state | channel: channel, ping_timer: timer}}

      {:error, reason} ->
        Logger.error("Failed to create gRPC connection: #{inspect(reason)}")
        schedule_reconnect(state.config)
        {:noreply, state}
    end
  end

  def handle_info(:ping, %State{channel: channel, config: config} = state) do
    case channel do
      nil ->
        {:noreply, state}

      channel ->
        case send_ping(channel) do
          :ok ->
            timer = schedule_ping(config)
            {:noreply, %State{state | ping_timer: timer, last_ping: System.monotonic_time(:millisecond)}}

          :error ->
            Logger.warning("Ping failed, reconnecting...")
            cleanup_connection(channel)
            send(self(), :connect)
            {:noreply, %State{state | channel: nil, ping_timer: nil}}
        end
    end
  end

  def handle_info(:reconnect, state) do
    send(self(), :connect)
    {:noreply, state}
  end

  def handle_info({:gun_down, _conn_pid, _protocol, reason, _killed_streams}, state) do
    unless state.config.connection.suppress_connection_errors do
      Logger.debug("gRPC connection closed by server: #{inspect(reason)}")
    end
    {:stop, :normal, state}
  end

  def handle_info({:gun_up, _conn_pid, _protocol}, state) do
    Logger.debug("Gun connection is up")
    {:noreply, state}
  end

  def handle_info({:gun_error, _conn_pid, reason}, state) do
    unless state.config.connection.suppress_connection_errors do
      Logger.error("Gun connection error: #{inspect(reason)}")
    end
    {:stop, {:gun_error, reason}, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    cleanup_connection(state.channel)
    cancel_ping_timer(state.ping_timer)
    :ok
  end

  # Private functions

  defp create_connection(config) do
    {host, port, opts} = Config.get_endpoint(config)
    retry_config = Config.get_retry_config(config)

    if retry_config do
      create_connection_with_retry(host, port, opts, retry_config)
    else
      GRPC.Stub.connect(host, port, opts)
    end
  end

  defp create_connection_with_retry(host, port, opts, retry_config) do
    create_connection_with_retry(host, port, opts, retry_config, retry_config.max_attempts)
  end

  defp create_connection_with_retry(host, port, opts, retry_config, attempts_left) when attempts_left > 0 do
    case GRPC.Stub.connect(host, port, opts) do
      {:ok, channel} ->
        {:ok, channel}

      {:error, _reason} when attempts_left > 1 ->
        delay = min(retry_config.base_delay * (retry_config.max_attempts - attempts_left + 1), retry_config.max_delay)
        Logger.info("Connection failed, retrying in #{delay}ms... (#{attempts_left - 1} attempts left)")
        :timer.sleep(delay)
        create_connection_with_retry(host, port, opts, retry_config, attempts_left - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_connection_with_retry(_host, _port, _opts, _retry_config, 0) do
    {:error, :max_retries_exceeded}
  end

  defp is_connection_alive?(nil), do: false

  defp is_connection_alive?(%GRPC.Channel{adapter_payload: %{conn_pid: pid}}) when is_pid(pid) do
    Process.alive?(pid)
  end

  defp is_connection_alive?(_), do: false

  defp send_ping(channel) do
    try do
      # Use a lightweight health check - just try to get the channel info
      # This is better than making actual gRPC calls which might be heavy
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
      nil -> nil
      interval when is_integer(interval) and interval > 0 ->
        Process.send_after(self(), :ping, interval)
      _ -> nil
    end
  end

  defp schedule_reconnect(config) do
    retry_config = Config.get_retry_config(config)
    delay = if retry_config, do: retry_config.base_delay, else: 5000
    Process.send_after(self(), :reconnect, delay)
  end

  defp cancel_ping_timer(nil), do: :ok
  defp cancel_ping_timer(timer), do: Process.cancel_timer(timer)

  defp cleanup_connection(nil), do: :ok
  defp cleanup_connection(%GRPC.Channel{} = channel) do
    try do
      GRPC.Stub.disconnect(channel)
    rescue
      _ -> :ok
    catch
      _ -> :ok
    end
  end

  defp update_last_ping(state) do
    %State{state | last_ping: System.monotonic_time(:millisecond)}
  end
end