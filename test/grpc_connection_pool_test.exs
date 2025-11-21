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

      # Give workers time to attempt connection
      Process.sleep(100)

      # Check status
      status = Pool.status(pool_name)
      assert status.pool_name == pool_name
      assert status.expected_size == 2
      # Status will be :down or :degraded since no real gRPC server is running
      assert status.status in [:down, :degraded, :healthy]

      # Stop pool
      assert :ok = Pool.stop(pool_name)
    end

    test "returns error when no connections available", %{config: config, pool_name: pool_name} do
      # Start pool (will fail to connect since no server is running)
      case Pool.start_link(config, name: pool_name) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      # Give workers time to fail initial connection
      Process.sleep(100)

      # Try to get a channel - should fail since no gRPC server is running
      result = Pool.get_channel(pool_name)

      # Should return error since no connections are available
      assert result == {:error, :not_connected}

      Pool.stop(pool_name)
    end
  end
end
