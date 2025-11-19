defmodule GrpcConnectionPoolTest do
  use ExUnit.Case
  doctest GrpcConnectionPool

  alias GrpcConnectionPool.{Config, Pool}

  describe "config creation" do
    test "creates production config" do
      {:ok, config} = Config.production(host: "api.example.com", port: 443, pool_size: 5)

      assert config.endpoint.type == :production
      assert config.endpoint.host == "api.example.com"
      assert config.endpoint.port == 443
      assert config.pool.size == 5
    end

    test "creates local config" do
      {:ok, config} = Config.local(host: "localhost", port: 9090, pool_size: 3)

      assert config.endpoint.type == :local
      assert config.endpoint.host == "localhost"
      assert config.endpoint.port == 9090
      assert config.pool.size == 3
    end

    test "validates required fields" do
      assert {:error, _} = Config.production([])
    end
  end

  describe "pool management" do
    setup do
      # Create a config for local testing
      {:ok, config} = Config.local(host: "localhost", port: 8085, pool_size: 2)
      pool_name = :"test_pool_#{:rand.uniform(10000)}"

      %{config: config, pool_name: pool_name}
    end

    test "starts and stops pool", %{config: config, pool_name: pool_name} do
      # Start pool
      assert {:ok, pid} = Pool.start_link(config, name: pool_name)
      assert is_pid(pid)

      # Check status
      status = Pool.status(pool_name)
      assert status.pool_name == pool_name
      assert status.status == :running

      # Stop pool
      assert :ok = Pool.stop(pool_name)
    end

    test "executes operations", %{config: config, pool_name: pool_name} do
      # Start pool
      case Pool.start_link(config, name: pool_name) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      # Simple operation that doesn't require actual gRPC server
      operation = fn _channel ->
        {:ok, :test_result}
      end

      # Note: This operation returns a result directly, not making actual gRPC calls
      # but it tests the pool execution path
      result = Pool.execute(operation, pool: pool_name)

      # The operation should succeed since it doesn't make actual network calls
      assert match?({:ok, {:ok, :test_result}}, result)

      Pool.stop(pool_name)
    end
  end
end
