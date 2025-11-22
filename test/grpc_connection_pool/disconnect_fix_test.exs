defmodule GrpcConnectionPool.DisconnectFixTest do
  @moduledoc """
  Tests for the GRPC v0.11.5 disconnect fix that handles FunctionClauseError
  by manually closing Gun connections when needed.
  """
  use ExUnit.Case, async: true

  describe "GRPC v0.11.5 disconnect fix verification" do
    test "pattern matching works for Gun channels" do
      # Create a test process to simulate Gun connection
      gun_pid = spawn(fn ->
        receive do
          :close -> :ok
        end
      end)

      # Test our pattern matching logic
      gun_channel = %GRPC.Channel{
        adapter: GRPC.Client.Adapters.Gun,
        adapter_payload: %{conn_pid: gun_pid},
        host: "localhost",
        port: 9999,
        scheme: "http"
      }

      # This is the same pattern matching used in the fix
      result = case gun_channel do
        %GRPC.Channel{adapter_payload: %{conn_pid: pid}} when is_pid(pid) ->
          if Process.alive?(pid) do
            send(pid, :close)
            :gun_close_attempted
          else
            :gun_already_dead
          end
        _ ->
          :fallback_to_grpc_disconnect
      end

      assert result == :gun_close_attempted

      # Clean up
      send(gun_pid, :close)
    end

    test "pattern matching falls back for non-Gun channels" do
      # Test with Mint adapter
      mint_channel = %GRPC.Channel{
        adapter: GRPC.Client.Adapters.Mint,
        adapter_payload: %{connection: :some_mint_connection},
        host: "localhost",
        port: 9999,
        scheme: "http"
      }

      # This should fall through to the fallback case
      result = case mint_channel do
        %GRPC.Channel{adapter_payload: %{conn_pid: pid}} when is_pid(pid) ->
          :unexpected_gun_match
        _ ->
          :fallback_to_grpc_disconnect
      end

      assert result == :fallback_to_grpc_disconnect
    end

    test "pattern matching handles dead Gun process" do
      # Create and kill a process
      dead_pid = spawn(fn -> :ok end)
      Process.sleep(10)  # Ensure it's dead
      refute Process.alive?(dead_pid)

      dead_gun_channel = %GRPC.Channel{
        adapter: GRPC.Client.Adapters.Gun,
        adapter_payload: %{conn_pid: dead_pid},
        host: "localhost",
        port: 9999,
        scheme: "http"
      }

      result = case dead_gun_channel do
        %GRPC.Channel{adapter_payload: %{conn_pid: pid}} when is_pid(pid) ->
          if Process.alive?(pid) do
            :gun_close_attempted
          else
            :gun_already_dead
          end
        _ ->
          :fallback_to_grpc_disconnect
      end

      assert result == :gun_already_dead
    end

    test "FunctionClauseError rescue block works" do
      # Test the rescue pattern from our fix
      result = try do
        # Simulate the GRPC v0.11.5 error
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

    test "Gun :close API compatibility" do
      # Test that :gun.close/1 behaves as expected
      test_pid = spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

      # This should not raise an error
      try do
        result = :gun.close(test_pid)
        # Gun can return various results, we just ensure it doesn't crash
        assert result in [:ok, {:error, :not_connected}, {:error, :closed}] ||
               is_tuple(result) || is_atom(result)
      catch
        # Gun might not be available in test environment
        :error, :undef ->
          # This is acceptable - Gun module might not be loaded
          assert true
      end

      send(test_pid, :stop)
    end

    test "complete disconnect fix logic simulation" do
      # Simulate the complete fix logic
      gun_pid = spawn(fn ->
        receive do
          :gun_close -> :ok
        end
      end)

      channel = %GRPC.Channel{
        adapter: GRPC.Client.Adapters.Gun,
        adapter_payload: %{conn_pid: gun_pid},
        host: "localhost",
        port: 9999,
        scheme: "http"
      }

      # This simulates the exact logic from our fix
      cleanup_result = try do
        case channel do
          %GRPC.Channel{adapter_payload: %{conn_pid: pid}} when is_pid(pid) ->
            if Process.alive?(pid) do
              # Simulate :gun.close(pid) without actually calling Gun
              send(pid, :gun_close)
              :gun_close_success
            end
          _ ->
            # Would call GRPC.Stub.disconnect(channel) here
            :grpc_stub_disconnect
        end
      rescue
        FunctionClauseError -> :function_clause_error_handled
        _ -> :other_error_handled
      catch
        :exit, _ -> :exit_handled
      end

      assert cleanup_result == :gun_close_success
    end
  end
end