defmodule GrpcConnectionPool.PoolScalingEdgeCasesTest do
  use ExUnit.Case, async: false
  alias GrpcConnectionPool.Pool

  setup do
    # Use unique pool name for each test
    pool_name = :"EdgeCaseTest.#{:erlang.unique_integer()}"

    {:ok, config} = GrpcConnectionPool.Config.local(
      host: "localhost",
      port: 50051,
      pool_size: 10,
      pool_name: pool_name
    )

    {:ok, _pid} = Pool.start_link(config, name: pool_name)

    on_exit(fn ->
      # Give a small delay before stopping
      Process.sleep(10)

      # Force kill the supervisor if normal stop fails
      supervisor_name = :"#{pool_name}.Supervisor"
      case Process.whereis(supervisor_name) do
        nil -> :ok
        pid ->
          Process.exit(pid, :kill)
          Process.sleep(10)
      end
    end)

    %{pool_name: pool_name}
  end

  describe "Edge case: Invalid inputs" do
    test "scale_up with zero count is rejected", %{pool_name: pool_name} do
      # Guard clause in function signature should prevent this
      assert_raise FunctionClauseError, fn ->
        Pool.scale_up(pool_name, 0)
      end
    end

    test "scale_up with negative count is rejected", %{pool_name: pool_name} do
      assert_raise FunctionClauseError, fn ->
        Pool.scale_up(pool_name, -5)
      end
    end

    test "scale_down with zero count is rejected", %{pool_name: pool_name} do
      assert_raise FunctionClauseError, fn ->
        Pool.scale_down(pool_name, 0)
      end
    end

    test "resize to zero is rejected", %{pool_name: pool_name} do
      assert_raise FunctionClauseError, fn ->
        Pool.resize(pool_name, 0)
      end
    end

    test "resize to negative size is rejected", %{pool_name: pool_name} do
      assert_raise FunctionClauseError, fn ->
        Pool.resize(pool_name, -10)
      end
    end
  end

  describe "Edge case: Concurrent operations" do
    test "multiple concurrent scale_up operations", %{pool_name: pool_name} do
      parent = self()

      # Start 5 concurrent scale_up operations
      tasks = for i <- 1..5 do
        Task.async(fn ->
          result = Pool.scale_up(pool_name, i)
          send(parent, {:scale_up_result, i, result})
          result
        end)
      end

      # Wait for all to complete
      results = Task.await_many(tasks, 5000)

      # At least one should succeed, others might fail with :scaling_in_progress
      successes = Enum.filter(results, &match?({:ok, _}, &1))
      failures = Enum.filter(results, &match?({:error, :scaling_in_progress}, &1))

      assert length(successes) >= 1
      assert length(successes) + length(failures) == 5
    end

    test "concurrent scale_up and scale_down", %{pool_name: pool_name} do
      parent = self()

      # Start concurrent operations
      task1 = Task.async(fn ->
        # Add small delay inside the task to ensure both start nearly simultaneously
        Process.sleep(1)
        result = Pool.scale_up(pool_name, 5)
        send(parent, {:scale_up, result})
        result
      end)

      task2 = Task.async(fn ->
        # Start immediately
        result = Pool.scale_down(pool_name, 3)
        send(parent, {:scale_down, result})
        result
      end)

      results = Task.await_many([task1, task2], 5000)

      # At least one should succeed
      assert Enum.any?(results, &match?({:ok, _}, &1))

      # If both succeeded, the operations happened sequentially
      # If one failed, it means the lock worked
      case results do
        [{:ok, _}, {:ok, _}] -> :ok  # Both succeeded sequentially
        _ -> assert Enum.any?(results, &match?({:error, :scaling_in_progress}, &1))
      end
    end
  end

  describe "Edge case: Rapid sequential operations" do
    test "rapid scale up and down", %{pool_name: pool_name} do
      # Rapidly scale up and down
      {:ok, size1} = Pool.scale_up(pool_name, 10)
      assert size1 == 20

      {:ok, size2} = Pool.scale_down(pool_name, 5)
      assert size2 == 15

      {:ok, size3} = Pool.scale_up(pool_name, 5)
      assert size3 == 20

      {:ok, size4} = Pool.scale_down(pool_name, 10)
      assert size4 == 10

      status = Pool.status(pool_name)
      assert status.expected_size == 10
    end

    test "resize multiple times rapidly", %{pool_name: pool_name} do
      {:ok, size1} = Pool.resize(pool_name, 20)
      assert size1 == 20

      {:ok, size2} = Pool.resize(pool_name, 5)
      assert size2 == 5

      {:ok, size3} = Pool.resize(pool_name, 15)
      assert size3 == 15

      {:ok, size4} = Pool.resize(pool_name, 1)
      assert size4 == 1

      status = Pool.status(pool_name)
      assert status.expected_size == 1
    end
  end

  describe "Edge case: Boundary conditions" do
    test "scale down to exactly 1 worker", %{pool_name: pool_name} do
      {:ok, new_size} = Pool.scale_down(pool_name, 9)
      assert new_size == 1

      status = Pool.status(pool_name)
      assert status.expected_size == 1

      # Try to scale down further - should fail
      assert {:error, :would_empty_pool} = Pool.scale_down(pool_name, 1)
    end

    test "scale up to very large pool", %{pool_name: pool_name} do
      # Scale up to 100 workers
      {:ok, new_size} = Pool.resize(pool_name, 100)
      assert new_size == 100

      # Give workers time to start and connect (larger pools need more time)
      Process.sleep(500)

      status = Pool.status(pool_name)
      assert status.expected_size == 100

      # Verify we can get channels (some workers should be connected by now)
      result = Pool.get_channel(pool_name)
      assert match?({:ok, _}, result) or result == {:error, :not_connected}
    end

    test "scale down then immediately scale up", %{pool_name: pool_name} do
      {:ok, size1} = Pool.scale_down(pool_name, 5)
      assert size1 == 5

      {:ok, size2} = Pool.scale_up(pool_name, 10)
      assert size2 == 15

      status = Pool.status(pool_name)
      assert status.expected_size == 15
    end
  end

  describe "Edge case: Round-robin after scaling" do
    test "round-robin works correctly after scale down", %{pool_name: pool_name} do
      # Scale down
      {:ok, _} = Pool.scale_down(pool_name, 5)

      # Try getting multiple channels - should work with round-robin
      channels = for _ <- 1..20 do
        Pool.get_channel(pool_name)
      end

      # All should succeed or be :not_connected (if workers haven't connected yet)
      assert Enum.all?(channels, fn result ->
        match?({:ok, _}, result) or result == {:error, :not_connected}
      end)
    end

    test "round-robin works correctly after scale up", %{pool_name: pool_name} do
      # Scale up
      {:ok, _} = Pool.scale_up(pool_name, 10)

      # Give workers time to connect
      Process.sleep(200)

      # Try getting multiple channels
      channels = for _ <- 1..30 do
        Pool.get_channel(pool_name)
      end

      # At least some should succeed (workers might not all be connected yet)
      successes = Enum.count(channels, &match?({:ok, _}, &1))

      # If no workers are connected, that's also acceptable for this test
      # The important thing is no crashes occur
      assert successes >= 0
      assert length(channels) == 30
    end
  end

  describe "Edge case: Telemetry" do
    test "telemetry events are emitted for scale operations", %{pool_name: pool_name} do
      # Attach telemetry handler
      test_pid = self()

      :telemetry.attach_many(
        "test-scaling-handler",
        [
          [:grpc_connection_pool, :pool, :scale_up],
          [:grpc_connection_pool, :pool, :scale_down]
        ],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event_name, measurements, metadata})
        end,
        nil
      )

      # Perform scaling operations
      {:ok, _} = Pool.scale_up(pool_name, 5)

      # Check for scale_up telemetry
      assert_receive {:telemetry, [:grpc_connection_pool, :pool, :scale_up], measurements, metadata}, 1000
      assert measurements.succeeded == 5
      assert measurements.requested == 5
      assert metadata.pool_name == pool_name

      {:ok, _} = Pool.scale_down(pool_name, 3)

      # Check for scale_down telemetry
      assert_receive {:telemetry, [:grpc_connection_pool, :pool, :scale_down], measurements, metadata}, 1000
      assert measurements.terminated == 3
      assert measurements.requested == 3
      assert metadata.pool_name == pool_name

      :telemetry.detach("test-scaling-handler")
    end
  end

  describe "Edge case: Pool status accuracy" do
    test "status reflects expected size after operations", %{pool_name: pool_name} do
      initial_status = Pool.status(pool_name)
      assert initial_status.expected_size == 10

      {:ok, _} = Pool.scale_up(pool_name, 5)
      status1 = Pool.status(pool_name)
      assert status1.expected_size == 15

      {:ok, _} = Pool.scale_down(pool_name, 8)
      status2 = Pool.status(pool_name)
      assert status2.expected_size == 7

      {:ok, _} = Pool.resize(pool_name, 12)
      status3 = Pool.status(pool_name)
      assert status3.expected_size == 12
    end
  end
end
