defmodule GrpcConnectionPool.ConnectPathTest do
  @moduledoc """
  Exercises the real connect path — worker → `GRPC.Stub.connect` → slot claim →
  `get_channel/1` — against an in-process HTTP/2 server, with no external emulator.

  grpc >= 1.0 is client-only (`GRPC.Server` was removed), so we stand up a bare
  Cowboy HTTP/2 (h2c) listener instead. The pool only needs the HTTP/2 connection
  to come up to register a channel; it never dispatches an RPC here, so the
  handler is a stub that is never invoked.
  """
  use ExUnit.Case, async: false

  alias GrpcConnectionPool.{Config, Pool}

  @listener __MODULE__.Listener

  # Cowboy handler stub — the pool never sends an RPC, so this is never called.
  defmodule Handler do
    def init(req, state), do: {:ok, :cowboy_req.reply(200, %{}, "", req), state}
  end

  setup do
    # Port 0 → OS-assigned free port (avoids cross-test port collisions).
    # `start_clear` auto-detects the HTTP/2 connection preface (h2c prior
    # knowledge), which is what the gRPC Gun client speaks over plain HTTP.
    dispatch = :cowboy_router.compile([{:_, [{:_, Handler, []}]}])

    {:ok, _} =
      :cowboy.start_clear(@listener, [{:port, 0}], %{env: %{dispatch: dispatch}})

    port = :ranch.get_port(@listener)
    pool_name = :"connect_path_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      try do
        Pool.stop(pool_name)
      catch
        :exit, _ -> :ok
      end

      :cowboy.stop_listener(@listener)
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
