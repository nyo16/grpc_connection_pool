defmodule GrpcConnectionPool.TestServer do
  @moduledoc """
  A bare Cowboy HTTP/2 (h2c) listener for exercising the real connect/disconnect
  path in tests.

  grpc >= 1.0 is client-only (`GRPC.Server` was removed), so tests stand up a
  plain Cowboy h2c listener for the gRPC Gun client to connect to. The pool only
  needs the HTTP/2 connection to come up; it never dispatches an RPC here, so the
  handler is a stub that is never invoked.
  """

  # Cowboy handler stub — the pool never sends an RPC, so this is never called.
  defmodule Handler do
    @moduledoc false
    def init(req, state), do: {:ok, :cowboy_req.reply(200, %{}, "", req), state}
  end

  @doc """
  Starts an h2c listener on an OS-assigned free port. Returns `{ref, port}`.

  `start_clear` auto-detects the HTTP/2 connection preface (h2c prior knowledge),
  which is what the gRPC Gun client speaks over plain HTTP.
  """
  @spec start!(atom()) :: {atom(), :inet.port_number()}
  def start!(ref \\ unique_ref()) do
    dispatch = :cowboy_router.compile([{:_, [{:_, Handler, []}]}])
    {:ok, _} = :cowboy.start_clear(ref, [{:port, 0}], %{env: %{dispatch: dispatch}})
    {ref, :ranch.get_port(ref)}
  end

  @doc "Stops the listener. Safe to call if already stopped."
  @spec stop(atom()) :: :ok
  def stop(ref) do
    :cowboy.stop_listener(ref)
    :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  Force-drops all established connections by killing the ranch connection
  processes, simulating a server-side crash/RST.

  This is the reliable way to surface a real disconnect to the client: unlike
  `stop_listener/1` (which only stops the acceptor and leaves established
  connections open), killing the connection process closes the live socket, so
  the client's gun process dies and the pool detects the drop.
  """
  @spec drop_connections(atom()) :: :ok
  def drop_connections(ref) do
    case :ranch.procs(ref, :connections) do
      [] ->
        # Surface an ordering bug loudly: call this only after the client has
        # connected, otherwise there is nothing to drop and the test would
        # silently miss the disconnect it means to trigger.
        raise "TestServer.drop_connections/1: no established connections on #{inspect(ref)}"

      conns ->
        Enum.each(conns, &Process.exit(&1, :kill))
    end

    :ok
  end

  @doc """
  Polls `fun` until it returns true; returns `true` if it did, `false` on timeout.

  Returns a boolean (rather than `:ok`) so callers can `assert` on it — a silent
  `:ok` on timeout would let a test proceed against an unmet precondition.
  """
  @spec wait_until((-> boolean()), non_neg_integer()) :: boolean()
  def wait_until(fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(25)
        do_wait_until(fun, deadline)
    end
  end

  defp unique_ref, do: :"grpc_test_server_#{System.unique_integer([:positive])}"
end
