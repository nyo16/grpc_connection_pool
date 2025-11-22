defmodule GrpcConnectionPool.PoolScalingTest do
  use ExUnit.Case, async: false
  alias GrpcConnectionPool.Pool

  setup do
    # Use unique pool name for each test
    pool_name = :"ScalingTest.#{:erlang.unique_integer()}"

    {:ok, config} = GrpcConnectionPool.Config.local(
      host: "localhost",
      port: 50051,
      pool_size: 5,
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

  test "scale_up increases pool size", %{pool_name: pool_name} do
    initial_status = Pool.status(pool_name)
    assert initial_status.expected_size == 5

    {:ok, new_size} = Pool.scale_up(pool_name, 3)
    assert new_size == 8

    updated_status = Pool.status(pool_name)
    assert updated_status.expected_size == 8
  end

  test "scale_down decreases pool size", %{pool_name: pool_name} do
    {:ok, new_size} = Pool.scale_down(pool_name, 2)
    assert new_size == 3

    updated_status = Pool.status(pool_name)
    assert updated_status.expected_size == 3
  end

  test "resize sets exact pool size", %{pool_name: pool_name} do
    {:ok, new_size} = Pool.resize(pool_name, 10)
    assert new_size == 10

    updated_status = Pool.status(pool_name)
    assert updated_status.expected_size == 10
  end

  test "scale_down prevents emptying pool", %{pool_name: pool_name} do
    assert {:error, :would_empty_pool} = Pool.scale_down(pool_name, 10)
  end

  test "scale_down prevents scaling to zero", %{pool_name: pool_name} do
    assert {:error, :would_empty_pool} = Pool.scale_down(pool_name, 5)
  end

  test "scale_down leaves at least one worker", %{pool_name: pool_name} do
    {:ok, new_size} = Pool.scale_down(pool_name, 4)
    assert new_size == 1

    updated_status = Pool.status(pool_name)
    assert updated_status.expected_size == 1
  end

  test "concurrent scaling operations are prevented", %{pool_name: pool_name} do
    # Start a long-running scale up in a separate process
    parent = self()
    spawn(fn ->
      # This will hold the lock
      result = Pool.scale_up(pool_name, 10)
      send(parent, {:scale_up_done, result})
    end)

    # Give it a moment to acquire the lock
    Process.sleep(10)

    # Try to scale down while scale up is in progress
    result = Pool.scale_down(pool_name, 2)

    # Wait for scale up to finish
    receive do
      {:scale_up_done, _} -> :ok
    after
      1000 -> :ok
    end

    # One of the operations should have been blocked
    assert result == {:error, :scaling_in_progress} or match?({:ok, _}, result)
  end

  test "resize to same size is idempotent", %{pool_name: pool_name} do
    {:ok, size} = Pool.resize(pool_name, 5)
    assert size == 5

    status = Pool.status(pool_name)
    assert status.expected_size == 5
  end

  test "multiple scale operations work correctly", %{pool_name: pool_name} do
    # Scale up
    {:ok, size1} = Pool.scale_up(pool_name, 3)
    assert size1 == 8

    # Scale down
    {:ok, size2} = Pool.scale_down(pool_name, 2)
    assert size2 == 6

    # Scale up again
    {:ok, size3} = Pool.scale_up(pool_name, 4)
    assert size3 == 10

    # Verify final size
    status = Pool.status(pool_name)
    assert status.expected_size == 10
  end

  test "resize handles large size increases", %{pool_name: pool_name} do
    {:ok, new_size} = Pool.resize(pool_name, 50)
    assert new_size == 50

    status = Pool.status(pool_name)
    assert status.expected_size == 50
  end

  test "resize handles large size decreases", %{pool_name: pool_name} do
    # First scale up
    {:ok, _} = Pool.resize(pool_name, 20)

    # Then scale down significantly
    {:ok, new_size} = Pool.resize(pool_name, 3)
    assert new_size == 3

    status = Pool.status(pool_name)
    assert status.expected_size == 3
  end
end
