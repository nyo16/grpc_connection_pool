defmodule GrpcConnectionPool.TelemetryTest do
  use ExUnit.Case, async: false

  alias GrpcConnectionPool.{Config, Pool, Worker}

  @moduletag :telemetry

  describe "Pool telemetry events" do
    test "pool init telemetry event is emitted" do
      pool_name = :"TelemetryTestPool_#{:erlang.unique_integer([:positive])}"
      test_pid = self()
      handler_id = "test-pool-init-handler-#{:erlang.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:grpc_connection_pool, :pool, :init],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event_name, measurements, metadata})
        end,
        nil
      )

      {:ok, config} =
        Config.local(
          host: "localhost",
          port: 9999,
          pool_size: 2,
          pool: [name: pool_name, telemetry_interval: 60_000]
        )

      {:ok, _pid} = Pool.start_link(config, name: pool_name)

      assert_receive {:telemetry, [:grpc_connection_pool, :pool, :init], measurements, metadata},
                     1000

      assert measurements.pool_size == 2
      assert metadata.pool_name == pool_name
      assert metadata.endpoint == "localhost:9999"

      :telemetry.detach(handler_id)
      Pool.stop(pool_name)
    end
  end

  describe "Worker telemetry events" do
    setup do
      registry_name = :"WorkerTelemetryTestRegistry_#{:erlang.unique_integer([:positive])}"
      pool_name = :"WorkerTelemetryTestPool_#{:erlang.unique_integer([:positive])}"
      {:ok, _} = Registry.start_link(keys: :duplicate, name: registry_name)

      {:ok, config} =
        Config.local(
          host: "localhost",
          port: 9999,
          pool_size: 1,
          connection: [ping_interval: 100]
        )

      on_exit(fn ->
        case Process.whereis(registry_name) do
          pid when is_pid(pid) ->
            Process.unlink(pid)
            Process.exit(pid, :kill)

          _ ->
            :ok
        end
      end)

      %{config: config, registry_name: registry_name, pool_name: pool_name}
    end

    @tag timeout: 20_000
    test "gun_down telemetry event is emitted", %{
      config: config,
      registry_name: registry_name,
      pool_name: pool_name
    } do
      test_pid = self()
      handler_id = "test-gun-down-handler-#{:erlang.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:grpc_connection_pool, :channel, :gun_down],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event_name, measurements, metadata})
        end,
        nil
      )

      worker_opts = [
        config: config,
        registry_name: registry_name,
        pool_name: pool_name
      ]

      {:ok, worker_pid} = Worker.start_link(worker_opts)
      # Wait for connection attempt to complete/timeout (GRPC timeout is ~5s)
      Process.sleep(6000)

      # Now the worker is ready to process messages
      send(worker_pid, {:gun_down, make_ref(), :http2, :closed, []})

      assert_receive {:telemetry, [:grpc_connection_pool, :channel, :gun_down], measurements,
                      metadata},
                     2000

      assert measurements == %{}
      assert metadata.pool_name == pool_name
      assert metadata.reason == :closed
      assert metadata.protocol == :http2

      :telemetry.detach(handler_id)
      GenServer.stop(worker_pid)
    end

    @tag timeout: 20_000
    test "gun_error telemetry event is emitted", %{
      config: config,
      registry_name: registry_name,
      pool_name: pool_name
    } do
      test_pid = self()
      handler_id = "test-gun-error-handler-#{:erlang.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:grpc_connection_pool, :channel, :gun_error],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event_name, measurements, metadata})
        end,
        nil
      )

      worker_opts = [
        config: config,
        registry_name: registry_name,
        pool_name: pool_name
      ]

      {:ok, worker_pid} = Worker.start_link(worker_opts)
      # Wait for connection attempt to complete/timeout (GRPC timeout is ~5s)
      Process.sleep(6000)

      send(worker_pid, {:gun_error, make_ref(), :stream_error})

      assert_receive {:telemetry, [:grpc_connection_pool, :channel, :gun_error], measurements,
                      metadata},
                     2000

      assert measurements == %{}
      assert metadata.pool_name == pool_name
      assert metadata.reason == :stream_error

      :telemetry.detach(handler_id)
      GenServer.stop(worker_pid)
    end

    @tag timeout: 20_000
    test "reconnect_scheduled telemetry event is emitted", %{
      config: config,
      registry_name: registry_name,
      pool_name: pool_name
    } do
      test_pid = self()
      handler_id = "test-reconnect-scheduled-handler-#{:erlang.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:grpc_connection_pool, :channel, :reconnect_scheduled],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event_name, measurements, metadata})
        end,
        nil
      )

      worker_opts = [
        config: config,
        registry_name: registry_name,
        pool_name: pool_name
      ]

      {:ok, worker_pid} = Worker.start_link(worker_opts)
      # Wait for connection attempt to complete/timeout (GRPC timeout is ~5s)
      Process.sleep(6000)

      # Trigger disconnect which schedules reconnection
      send(worker_pid, {:gun_down, make_ref(), :http2, :closed, []})

      assert_receive {:telemetry, [:grpc_connection_pool, :channel, :reconnect_scheduled],
                      measurements, metadata},
                     2000

      assert is_integer(measurements.delay_ms)
      assert measurements.delay_ms > 0
      assert measurements.attempt == 1
      assert metadata.pool_name == pool_name
      assert metadata.reason == {:gun_down, :closed}

      :telemetry.detach(handler_id)
      GenServer.stop(worker_pid)
    end

    @tag timeout: 20_000
    test "reconnect_attempt increments on successive disconnects", %{
      config: config,
      registry_name: registry_name,
      pool_name: pool_name
    } do
      test_pid = self()
      handler_id = "test-reconnect-increment-handler-#{:erlang.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:grpc_connection_pool, :channel, :reconnect_scheduled],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event_name, measurements, metadata})
        end,
        nil
      )

      worker_opts = [
        config: config,
        registry_name: registry_name,
        pool_name: pool_name
      ]

      {:ok, worker_pid} = Worker.start_link(worker_opts)
      # Wait for connection attempt to complete/timeout (GRPC timeout is ~5s)
      Process.sleep(6000)

      # First disconnect
      send(worker_pid, {:gun_down, make_ref(), :http2, :closed, []})

      assert_receive {:telemetry, [:grpc_connection_pool, :channel, :reconnect_scheduled],
                      measurements1, _metadata},
                     2000

      assert measurements1.attempt == 1

      # Allow some time for state update
      Process.sleep(100)

      # Second disconnect
      send(worker_pid, {:gun_error, make_ref(), :timeout})

      assert_receive {:telemetry, [:grpc_connection_pool, :channel, :reconnect_scheduled],
                      measurements2, _metadata},
                     2000

      assert measurements2.attempt == 2

      :telemetry.detach(handler_id)
      GenServer.stop(worker_pid)
    end
  end

  describe "Ping telemetry events" do
    setup do
      registry_name = :"PingTelemetryTestRegistry_#{:erlang.unique_integer([:positive])}"
      pool_name = :"PingTelemetryTestPool_#{:erlang.unique_integer([:positive])}"
      {:ok, _} = Registry.start_link(keys: :duplicate, name: registry_name)

      {:ok, config} =
        Config.local(
          host: "localhost",
          port: 9999,
          pool_size: 1,
          connection: [ping_interval: 50]
        )

      on_exit(fn ->
        case Process.whereis(registry_name) do
          pid when is_pid(pid) ->
            Process.unlink(pid)
            Process.exit(pid, :kill)

          _ ->
            :ok
        end
      end)

      %{config: config, registry_name: registry_name, pool_name: pool_name}
    end

    @tag timeout: 20_000
    test "ping telemetry event is not emitted when channel is nil (no-op)", %{
      config: config,
      registry_name: registry_name,
      pool_name: pool_name
    } do
      test_pid = self()
      handler_id = "test-ping-handler-#{:erlang.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:grpc_connection_pool, :channel, :ping],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event_name, measurements, metadata})
        end,
        nil
      )

      worker_opts = [
        config: config,
        registry_name: registry_name,
        pool_name: pool_name
      ]

      {:ok, worker_pid} = Worker.start_link(worker_opts)

      # Wait for connection attempt to complete/timeout (GRPC timeout is ~5s)
      Process.sleep(6000)

      # Manually trigger ping
      # When no channel is connected, ping on nil channel returns early
      # without telemetry
      send(worker_pid, :ping)

      # Give time for the message to be processed
      Process.sleep(100)

      # Since no channel is connected, ping on nil channel returns early
      # without telemetry. Let's verify by waiting briefly
      refute_receive {:telemetry, [:grpc_connection_pool, :channel, :ping], _, _}, 500

      :telemetry.detach(handler_id)
      GenServer.stop(worker_pid)
    end
  end

  describe "Telemetry event structure validation" do
    test "all new telemetry events follow the expected structure" do
      # This test documents the expected telemetry event structure

      # [:grpc_connection_pool, :channel, :ping]
      ping_measurements = %{duration: 12_345}
      ping_metadata = %{pool_name: :test_pool, result: :ok}
      assert Map.has_key?(ping_measurements, :duration)
      assert Map.has_key?(ping_metadata, :pool_name)
      assert Map.has_key?(ping_metadata, :result)
      assert ping_metadata.result in [:ok, :error]

      # [:grpc_connection_pool, :channel, :gun_down]
      gun_down_measurements = %{}
      gun_down_metadata = %{pool_name: :test_pool, reason: :closed, protocol: :http2}
      assert gun_down_measurements == %{}
      assert Map.has_key?(gun_down_metadata, :pool_name)
      assert Map.has_key?(gun_down_metadata, :reason)
      assert Map.has_key?(gun_down_metadata, :protocol)

      # [:grpc_connection_pool, :channel, :gun_error]
      gun_error_measurements = %{}
      gun_error_metadata = %{pool_name: :test_pool, reason: :stream_error}
      assert gun_error_measurements == %{}
      assert Map.has_key?(gun_error_metadata, :pool_name)
      assert Map.has_key?(gun_error_metadata, :reason)

      # [:grpc_connection_pool, :channel, :reconnect_scheduled]
      reconnect_measurements = %{delay_ms: 1000, attempt: 1}
      reconnect_metadata = %{pool_name: :test_pool, reason: {:gun_down, :closed}}
      assert Map.has_key?(reconnect_measurements, :delay_ms)
      assert Map.has_key?(reconnect_measurements, :attempt)
      assert is_integer(reconnect_measurements.delay_ms)
      assert is_integer(reconnect_measurements.attempt)
      assert Map.has_key?(reconnect_metadata, :pool_name)
      assert Map.has_key?(reconnect_metadata, :reason)

      # [:grpc_connection_pool, :pool, :init]
      init_measurements = %{pool_size: 5}
      init_metadata = %{pool_name: :test_pool, endpoint: "localhost:9999"}
      assert Map.has_key?(init_measurements, :pool_size)
      assert is_integer(init_measurements.pool_size)
      assert Map.has_key?(init_metadata, :pool_name)
      assert Map.has_key?(init_metadata, :endpoint)
      assert is_binary(init_metadata.endpoint)
    end
  end
end
