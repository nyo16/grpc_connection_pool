defmodule GrpcConnectionPool.TelemetryTest do
  @moduledoc """
  Telemetry tests driven by REAL connects and disconnects against a Cowboy h2c
  server. Under grpc 1.0 the worker no longer receives gun messages, so disconnect
  telemetry is exercised by killing the server-side connection (a genuine drop)
  rather than synthesizing `:gun_down`/`:gun_error` messages.
  """
  use ExUnit.Case, async: false

  alias GrpcConnectionPool.{Config, Pool, Worker}
  alias GrpcConnectionPool.TestServer

  @moduletag :telemetry

  describe "pool telemetry events" do
    test "pool init event is emitted" do
      pool_name = :"TelemetryInit_#{System.unique_integer([:positive])}"
      attach([[:grpc_connection_pool, :pool, :init]])

      {:ok, config} = Config.local(host: "localhost", port: 9999, pool_size: 2)
      {:ok, _} = Pool.start_link(config, name: pool_name)
      on_exit(fn -> safe_stop(pool_name) end)

      assert_receive {:telemetry, [:grpc_connection_pool, :pool, :init], meas, meta}, 1_000
      assert meas.pool_size == 2
      assert meta.pool_name == pool_name
      assert meta.endpoint == "localhost:9999"
    end
  end

  describe "channel connect/disconnect telemetry (real drop)" do
    setup do
      {ref, port} = TestServer.start!()
      pool_name = :"TelemetryDrop_#{System.unique_integer([:positive])}"

      on_exit(fn ->
        safe_stop(pool_name)
        TestServer.stop(ref)
      end)

      %{ref: ref, port: port, pool_name: pool_name}
    end

    @tag :capture_log
    test "a real drop emits connection_down, disconnected, and reconnect_scheduled", ctx do
      attach([
        [:grpc_connection_pool, :channel, :connected],
        [:grpc_connection_pool, :channel, :connection_down],
        [:grpc_connection_pool, :channel, :disconnected],
        [:grpc_connection_pool, :channel, :reconnect_scheduled]
      ])

      start_pool!(ctx.port, ctx.pool_name)
      assert_receive {:telemetry, [:grpc_connection_pool, :channel, :connected], _, _}, 5_000

      TestServer.drop_connections(ctx.ref)

      assert_receive {:telemetry, [:grpc_connection_pool, :channel, :connection_down], cd_meas,
                      cd_meta},
                     2_000

      assert cd_meas == %{}
      assert cd_meta.pool_name == ctx.pool_name
      assert match?({:shutdown, _}, cd_meta.reason)

      assert_receive {:telemetry, [:grpc_connection_pool, :channel, :disconnected], dis_meas,
                      dis_meta},
                     2_000

      assert is_integer(dis_meas.duration)
      assert dis_meta.pool_name == ctx.pool_name
      assert match?({:connection_down, _}, dis_meta.reason)

      assert_receive {:telemetry, [:grpc_connection_pool, :channel, :reconnect_scheduled],
                      rs_meas, rs_meta},
                     2_000

      assert is_integer(rs_meas.delay_ms) and rs_meas.delay_ms > 0
      assert rs_meas.attempt >= 1
      assert rs_meta.pool_name == ctx.pool_name
      assert match?({:connection_down, _}, rs_meta.reason)
    end

    @tag :capture_log
    test "the pool reconnects to the live server after a drop", ctx do
      attach([[:grpc_connection_pool, :channel, :connected]])

      start_pool!(ctx.port, ctx.pool_name)
      # initial connect
      assert_receive {:telemetry, [:grpc_connection_pool, :channel, :connected], _, _}, 5_000

      TestServer.drop_connections(ctx.ref)

      # reconnect to the still-listening server
      assert_receive {:telemetry, [:grpc_connection_pool, :channel, :connected], _, _}, 5_000

      assert TestServer.wait_until(
               fn -> match?({:ok, %GRPC.Channel{}}, Pool.get_channel(ctx.pool_name)) end,
               2_000
             )
    end
  end

  describe "ping telemetry events" do
    setup do
      registry_name = :"PingTelemetryRegistry_#{System.unique_integer([:positive])}"
      pool_name = :"PingTelemetryPool_#{System.unique_integer([:positive])}"
      {:ok, _} = Registry.start_link(keys: :duplicate, name: registry_name)

      on_exit(fn ->
        case Process.whereis(registry_name) do
          pid when is_pid(pid) ->
            Process.unlink(pid)
            Process.exit(pid, :kill)

          _ ->
            :ok
        end
      end)

      %{registry_name: registry_name, pool_name: pool_name}
    end

    test "ping is a no-op (no event) when no channel is connected", ctx do
      attach([[:grpc_connection_pool, :channel, :ping]])

      {:ok, config} =
        Config.new(
          endpoint: [type: :local, host: "localhost", port: 9999],
          pool: [size: 1],
          connection: [ping_interval: 50, max_reconnect_attempts: 1_000]
        )

      {:ok, worker_pid} =
        Worker.start_link(
          config: config,
          registry_name: ctx.registry_name,
          pool_name: ctx.pool_name
        )

      # Dead port + retry: 0 -> connect fails fast -> channel stays nil.
      assert TestServer.wait_until(fn -> Worker.status(worker_pid) == :disconnected end, 1_000)
      send(worker_pid, :ping)
      refute_receive {:telemetry, [:grpc_connection_pool, :channel, :ping], _, _}, 300

      GenServer.stop(worker_pid)
    end
  end

  # Note: the live event shapes (connection_down, disconnected, reconnect_scheduled,
  # connected, pool init) are asserted directly in the real-drop and pool-init tests
  # above, so there is no separate hand-built "structure" test (it would be tautological).

  # --- helpers ---

  defp start_pool!(port, pool_name) do
    {:ok, config} =
      Config.new(
        endpoint: [type: :local, host: "localhost", port: port],
        pool: [size: 1, name: pool_name],
        # No ping (monitor is the detector) + short backoff so reconnect is quick.
        connection: [ping_interval: nil, backoff_min: 200]
      )

    {:ok, _} = Pool.start_link(config, name: pool_name)
    assert :ok = Pool.await_ready(pool_name, 5_000)
  end

  defp attach(events) do
    test_pid = self()
    handler_id = "tele-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, meas, meta, _ -> send(test_pid, {:telemetry, event, meas, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  defp safe_stop(pool_name) do
    Pool.stop(pool_name)
  catch
    :exit, _ -> :ok
  end
end
