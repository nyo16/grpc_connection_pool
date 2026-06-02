defmodule GrpcConnectionPool.ConnectPathTest do
  @moduledoc """
  Exercises the real connect path — worker → `GRPC.Stub.connect` → slot claim →
  `get_channel/1` — against an in-process gRPC server, with no external emulator.

  The pool only needs the HTTP/2 connection to come up to register a channel; it
  never dispatches an RPC here, so the embedded server implements no methods.
  """
  use ExUnit.Case, async: false

  alias GrpcConnectionPool.{Config, Pool}

  # Reuses a service definition from googleapis_proto_ex (test-only dep). No RPC
  # methods are implemented because the pool never calls one in these tests.
  defmodule TestServer do
    use GRPC.Server, service: Google.Pubsub.V1.Publisher.Service
  end

  setup do
    # Port 0 → OS-assigned free port (avoids cross-test port collisions).
    {:ok, _pid, port} = GRPC.Server.start(TestServer, 0)
    pool_name = :"connect_path_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      try do
        Pool.stop(pool_name)
      catch
        :exit, _ -> :ok
      end

      GRPC.Server.stop(TestServer)
    end)

    %{port: port, pool_name: pool_name}
  end

  test "workers connect, populate slots, and get_channel returns a channel", %{
    port: port,
    pool_name: pool_name
  } do
    {:ok, config} = Config.local(host: "localhost", port: port, pool_size: 3)
    {:ok, _sup} = Pool.start_link(config, name: pool_name)

    assert :ok = Pool.await_ready(pool_name, 5_000)

    # Give the remaining workers a moment to finish connecting.
    wait_until(fn -> Pool.status(pool_name).current_size == 3 end, 5_000)

    status = Pool.status(pool_name)
    assert status.current_size == 3
    assert status.status == :healthy

    # All slots 0..2 are populated and get_channel hands back a real channel.
    assert {:ok, %GRPC.Channel{}} = Pool.get_channel(pool_name)
  end

  defp wait_until(fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) >= deadline -> :ok
      true -> Process.sleep(25) && do_wait_until(fun, deadline)
    end
  end
end
