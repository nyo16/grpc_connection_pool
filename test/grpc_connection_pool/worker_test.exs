defmodule GrpcConnectionPool.WorkerTest do
  @moduledoc """
  Worker lifecycle tests against a real Cowboy h2c server.

  grpc 1.0's Gun adapter owns the socket in its own process, so the worker no
  longer receives `:gun_down`/`:gun_error` messages; disconnect detection is done
  by monitoring the inner gun process. These tests exercise the real connect →
  drop → reconnect path and graceful teardown rather than synthesizing adapter
  messages.
  """
  use ExUnit.Case, async: false

  alias GrpcConnectionPool.Config
  alias GrpcConnectionPool.TestServer
  alias GrpcConnectionPool.Worker

  describe "worker teardown" do
    setup do
      registry_name = :"WorkerTestRegistry_#{System.unique_integer([:positive])}"
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

      %{registry_name: registry_name}
    end

    @tag :capture_log
    test "terminates gracefully when the endpoint is unreachable", %{
      registry_name: registry_name
    } do
      # retry: 0 makes a dead-port connect fail fast, so the worker just keeps its
      # channel nil. Termination must not crash even with no live connection.
      {:ok, config} = Config.local(host: "localhost", port: 9999, pool_size: 1)

      {:ok, worker_pid} =
        Worker.start_link(config: config, registry_name: registry_name, pool_name: :worker_test)

      assert TestServer.wait_until(fn -> Worker.status(worker_pid) == :disconnected end, 1_000)

      GenServer.stop(worker_pid, :normal, 5_000)
      refute Process.alive?(worker_pid)
    end

    @tag :capture_log
    test "cleanup is idempotent after a real drop", %{registry_name: registry_name} do
      {ref, port} = TestServer.start!()
      on_exit(fn -> TestServer.stop(ref) end)

      {:ok, config} = Config.local(host: "localhost", port: port, pool_size: 1)

      {:ok, worker_pid} =
        Worker.start_link(config: config, registry_name: registry_name, pool_name: :worker_test)

      assert TestServer.wait_until(fn -> Worker.status(worker_pid) == :connected end, 5_000)

      # Real drop: kill the server-side connection so the client's gun process dies.
      TestServer.drop_connections(ref)
      assert TestServer.wait_until(fn -> Worker.status(worker_pid) == :disconnected end, 2_000)

      # terminate/2 runs cleanup_connection again — must not crash on the already
      # torn-down channel.
      GenServer.stop(worker_pid, :normal, 5_000)
      refute Process.alive?(worker_pid)
    end
  end
end
