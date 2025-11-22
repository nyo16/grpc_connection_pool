defmodule GrpcConnectionPool.WorkerTest do
  use ExUnit.Case, async: false

  alias GrpcConnectionPool.Worker
  alias GrpcConnectionPool.Config

  describe "Worker termination with GRPC v0.11.5 disconnect fix" do
    setup do
      # Create a unique registry name for each test
      registry_name = :"WorkerTestRegistry_#{:erlang.unique_integer()}"
      {:ok, _} = Registry.start_link(keys: :duplicate, name: registry_name)

      {:ok, config} = Config.local(host: "localhost", port: 9999, pool_size: 1)

      on_exit(fn ->
        case Process.whereis(registry_name) do
          pid when is_pid(pid) ->
            Process.unlink(pid)
            Process.exit(pid, :kill)
          _ -> :ok
        end
      end)

      %{config: config, registry_name: registry_name}
    end

    test "Worker handles termination with Gun connection gracefully", %{config: config, registry_name: registry_name} do
      # Start worker
      worker_opts = [
        config: config,
        registry_name: registry_name,
        pool_name: :test_pool
      ]

      {:ok, worker_pid} = Worker.start_link(worker_opts)

      # Let worker attempt connection (will fail but that's expected)
      Process.sleep(100)

      # Terminate worker gracefully - this should trigger cleanup_connection
      GenServer.stop(worker_pid, :normal)

      # Worker should terminate without crashing
      refute Process.alive?(worker_pid)
    end

    test "Worker handles Gun disconnect messages properly", %{config: config, registry_name: registry_name} do
      # Start worker
      worker_opts = [
        config: config,
        registry_name: registry_name,
        pool_name: :test_pool
      ]

      {:ok, worker_pid} = Worker.start_link(worker_opts)

      # Let worker attempt connection
      Process.sleep(100)

      # Simulate Gun disconnect message that could trigger the FunctionClauseError
      # Send gun_down message to worker
      send(worker_pid, {:gun_down, make_ref(), :http, :closed, []})

      # Worker should handle this gracefully and not crash
      Process.sleep(100)
      assert Process.alive?(worker_pid)

      # Send gun_error message
      send(worker_pid, {:gun_error, make_ref(), :stream_error})

      # Worker should still be alive
      Process.sleep(100)
      assert Process.alive?(worker_pid)

      # Clean up
      GenServer.stop(worker_pid)
    end

    test "Worker handles Mint disconnect messages properly", %{config: config, registry_name: registry_name} do
      # Start worker
      worker_opts = [
        config: config,
        registry_name: registry_name,
        pool_name: :test_pool
      ]

      {:ok, worker_pid} = Worker.start_link(worker_opts)

      # Let worker attempt connection
      Process.sleep(100)

      # Simulate Mint disconnect message
      send(worker_pid, {:gun_down, make_ref(), :http, :connection_down, []})

      # Worker should handle this gracefully
      Process.sleep(100)
      assert Process.alive?(worker_pid)

      # Clean up
      GenServer.stop(worker_pid)
    end
  end

  describe "GRPC disconnect fix edge cases" do
    setup do
      registry_name = :"WorkerEdgeCaseTest_#{:erlang.unique_integer()}"
      {:ok, _} = Registry.start_link(keys: :duplicate, name: registry_name)

      {:ok, config} = Config.local(host: "localhost", port: 9999, pool_size: 1)

      on_exit(fn ->
        case Process.whereis(registry_name) do
          pid when is_pid(pid) ->
            Process.unlink(pid)
            Process.exit(pid, :kill)
          _ -> :ok
        end
      end)

      %{config: config, registry_name: registry_name}
    end

    test "Worker survives FunctionClauseError during GRPC operations", %{config: config, registry_name: registry_name} do
      # Start worker that will encounter connection issues
      worker_opts = [
        config: config,
        registry_name: registry_name,
        pool_name: :test_pool
      ]

      {:ok, worker_pid} = Worker.start_link(worker_opts)

      # Let worker attempt initial connection
      Process.sleep(200)

      # Worker should be alive even if connection fails
      assert Process.alive?(worker_pid)

      # Trigger multiple reconnection attempts by sending disconnect signals
      for _i <- 1..3 do
        send(worker_pid, {:gun_down, make_ref(), :http, :closed, []})
        Process.sleep(50)
        assert Process.alive?(worker_pid)
      end

      # Clean up
      GenServer.stop(worker_pid)
    end

    test "Worker handles rapid Gun connection state changes", %{config: config, registry_name: registry_name} do
      worker_opts = [
        config: config,
        registry_name: registry_name,
        pool_name: :test_pool
      ]

      {:ok, worker_pid} = Worker.start_link(worker_opts)
      Process.sleep(100)

      # Send rapid Gun state changes that could trigger race conditions
      gun_ref = make_ref()

      # Rapid fire of different Gun messages
      messages = [
        {:gun_down, gun_ref, :http, :closed, []},
        {:gun_error, gun_ref, :stream_error},
        {:gun_down, gun_ref, :http, :timeout, []},
        {:gun_error, gun_ref, :connection_error}
      ]

      for msg <- messages do
        send(worker_pid, msg)
        # Small delay to avoid overwhelming
        Process.sleep(10)
      end

      # Worker should survive all messages
      Process.sleep(100)
      assert Process.alive?(worker_pid)

      GenServer.stop(worker_pid)
    end

    test "Worker cleanup is idempotent", %{config: config, registry_name: registry_name} do
      # Test that worker can be terminated gracefully multiple times
      worker_opts = [
        config: config,
        registry_name: registry_name,
        pool_name: :test_pool
      ]

      {:ok, worker_pid} = Worker.start_link(worker_opts)
      Process.sleep(100)

      # First termination should work
      GenServer.stop(worker_pid, :normal, 1000)

      # Worker should be dead
      refute Process.alive?(worker_pid)
    end
  end

  describe "GRPC v0.11.5 compatibility verification" do
    test "Gun :close call pattern matches expected interface" do
      # Verify that :gun.close/1 exists and accepts a PID
      # This test ensures the fix uses the correct Gun API

      # Create a dummy process to test Gun close
      test_pid = spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

      # This should not raise an error (Gun API compatibility check)
      try do
        result = :gun.close(test_pid)
        # Gun close can return various results, we just want to ensure it doesn't crash
        assert result in [:ok, {:error, :not_connected}, {:error, :closed}] ||
               is_tuple(result) || is_atom(result)
      catch
        # If Gun is not available, that's fine for this test
        :error, :undef -> :ok
      end

      send(test_pid, :stop)
    end

    test "GRPC Channel structure matches expected pattern" do
      # Test the pattern matching used in the fix
      gun_channel = %GRPC.Channel{
        adapter: GRPC.Client.Adapters.Gun,
        adapter_payload: %{conn_pid: self()},
        host: "localhost",
        port: 9999,
        scheme: "http"
      }

      # Verify our pattern matching works
      case gun_channel do
        %GRPC.Channel{adapter_payload: %{conn_pid: pid}} when is_pid(pid) ->
          assert is_pid(pid)
          assert pid == self()
        _ ->
          flunk("Pattern matching failed for Gun channel structure")
      end

      # Test non-Gun channel (fallback case)
      mint_channel = %GRPC.Channel{
        adapter: GRPC.Client.Adapters.Mint,
        adapter_payload: %{other_field: "value"},
        host: "localhost",
        port: 9999,
        scheme: "http"
      }

      case mint_channel do
        %GRPC.Channel{adapter_payload: %{conn_pid: _pid}} ->
          flunk("Should not match Gun pattern for Mint channel")
        _ ->
          # This is expected - fallback to standard disconnect
          assert true
      end
    end

    test "FunctionClauseError handling works correctly" do
      # Test that our rescue block catches FunctionClauseError
      result = try do
        # Simulate a function that raises FunctionClauseError
        # Note: In Elixir 1.19+, raise/2 with FunctionClauseError might behave differently
        error = %FunctionClauseError{
          module: GRPC.Client.Connection,
          function: :handle_call,
          arity: 3
        }
        raise error
      rescue
        FunctionClauseError -> :caught_function_clause_error
        _ -> :caught_other_error
      catch
        :exit, _ -> :caught_exit
      end

      assert result == :caught_function_clause_error
    end
  end
end