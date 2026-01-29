defmodule GrpcConnectionPool.ConfigTest do
  use ExUnit.Case, async: true

  alias GrpcConnectionPool.Config

  describe "interceptors configuration" do
    test "new/1 accepts interceptors in endpoint config" do
      {:ok, config} =
        Config.new(
          endpoint: [
            host: "localhost",
            port: 9090,
            interceptors: [MyApp.LoggingInterceptor, MyApp.AuthInterceptor]
          ]
        )

      assert config.endpoint.interceptors == [MyApp.LoggingInterceptor, MyApp.AuthInterceptor]
    end

    test "interceptors default to nil when not specified" do
      {:ok, config} = Config.new(endpoint: [host: "localhost", port: 9090])
      assert config.endpoint.interceptors == nil
    end

    test "get_endpoint includes interceptors in options when present" do
      {:ok, config} =
        Config.new(
          endpoint: [
            host: "localhost",
            port: 9090,
            interceptors: [MyApp.TestInterceptor]
          ]
        )

      {host, port, opts} = Config.get_endpoint(config)

      assert host == "localhost"
      assert port == 9090
      assert opts[:interceptors] == [MyApp.TestInterceptor]
    end

    test "get_endpoint excludes interceptors from options when nil" do
      {:ok, config} = Config.new(endpoint: [host: "localhost", port: 9090])

      {_host, _port, opts} = Config.get_endpoint(config)

      refute Keyword.has_key?(opts, :interceptors)
    end

    test "get_endpoint excludes interceptors from options when empty list" do
      {:ok, config} =
        Config.new(
          endpoint: [
            host: "localhost",
            port: 9090,
            interceptors: []
          ]
        )

      {_host, _port, opts} = Config.get_endpoint(config)

      refute Keyword.has_key?(opts, :interceptors)
    end

    test "multiple interceptors are preserved in order" do
      interceptors = [
        FirstInterceptor,
        SecondInterceptor,
        ThirdInterceptor,
        FourthInterceptor
      ]

      {:ok, config} =
        Config.new(
          endpoint: [
            host: "localhost",
            port: 9090,
            interceptors: interceptors
          ]
        )

      assert config.endpoint.interceptors == interceptors

      {_host, _port, opts} = Config.get_endpoint(config)
      assert opts[:interceptors] == interceptors
    end

    test "interceptors work with SSL configuration" do
      {:ok, config} =
        Config.new(
          endpoint: [
            host: "secure.example.com",
            port: 443,
            ssl: [verify: :verify_peer],
            interceptors: [MyApp.AuthInterceptor]
          ]
        )

      {_host, _port, opts} = Config.get_endpoint(config)

      assert opts[:interceptors] == [MyApp.AuthInterceptor]
      assert opts[:cred]
    end

    test "interceptors work with custom credentials" do
      cred = GRPC.Credential.new(ssl: [verify: :verify_peer])

      {:ok, config} =
        Config.new(
          endpoint: [
            host: "secure.example.com",
            port: 443,
            credentials: cred,
            interceptors: [MyApp.MetricsInterceptor]
          ]
        )

      {_host, _port, opts} = Config.get_endpoint(config)

      assert opts[:interceptors] == [MyApp.MetricsInterceptor]
      assert opts[:cred] == cred
    end
  end

  describe "endpoint type configuration" do
    test "interceptors work with production type" do
      {:ok, config} =
        Config.new(
          endpoint: [
            type: :production,
            host: "api.example.com",
            port: 443,
            interceptors: [MyApp.ProdInterceptor]
          ]
        )

      assert config.endpoint.type == :production
      assert config.endpoint.interceptors == [MyApp.ProdInterceptor]
    end

    test "interceptors work with local type" do
      {:ok, config} =
        Config.new(
          endpoint: [
            type: :local,
            host: "localhost",
            port: 9090,
            interceptors: [MyApp.DebugInterceptor]
          ]
        )

      assert config.endpoint.type == :local
      assert config.endpoint.interceptors == [MyApp.DebugInterceptor]
    end

    test "interceptors work with custom type" do
      {:ok, config} =
        Config.new(
          endpoint: [
            type: :staging,
            host: "staging.example.com",
            port: 443,
            interceptors: [MyApp.StagingInterceptor]
          ]
        )

      assert config.endpoint.type == :staging
      assert config.endpoint.interceptors == [MyApp.StagingInterceptor]
    end
  end

  describe "backward compatibility" do
    test "local/1 helper does not include interceptors by default" do
      {:ok, config} = Config.local(host: "localhost", port: 9090)

      assert config.endpoint.interceptors == nil
    end

    test "production/1 helper does not include interceptors by default" do
      {:ok, config} = Config.production(host: "api.example.com", port: 443)

      assert config.endpoint.interceptors == nil
    end

    test "existing configurations without interceptors continue to work" do
      {:ok, config} =
        Config.new(
          endpoint: [
            host: "localhost",
            port: 9090,
            ssl: []
          ],
          pool: [
            size: 10,
            name: MyApp.TestPool
          ],
          connection: [
            keepalive: 60_000,
            health_check: true
          ]
        )

      assert config.endpoint.host == "localhost"
      assert config.endpoint.port == 9090
      assert config.pool.size == 10
      assert config.connection.keepalive == 60_000
      assert config.endpoint.interceptors == nil

      {_host, _port, opts} = Config.get_endpoint(config)
      refute Keyword.has_key?(opts, :interceptors)
    end
  end
end
