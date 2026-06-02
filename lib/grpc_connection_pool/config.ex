defmodule GrpcConnectionPool.Config do
  @moduledoc """
  Configuration module for gRPC connection pooling.

  This module provides a unified configuration interface that works with both
  production gRPC services and local/test environments with custom endpoints.

  ## Configuration Options

  - `:endpoint` - Connection endpoint configuration
    - `:type` - Either `:production`, `:custom`, or any atom for different environments
    - `:host` - Hostname (required for custom endpoints)
    - `:port` - Port number (required for custom endpoints)
    - `:ssl` - SSL configuration (default: auto-configured based on type)
    - `:credentials` - Custom gRPC credentials
    - `:retry_config` - Retry configuration for connection failures
    - `:interceptors` - List of gRPC client interceptors (modules implementing the interceptor behavior)
  - `:pool` - Pool configuration
    - `:size` - Number of connections in pool (default: 5)
    - `:name` - Pool name (default: auto-generated)
    - `:strategy` - Channel selection strategy: `:round_robin` (default), `:random`,
      `:power_of_two`, or a custom module implementing `GrpcConnectionPool.Strategy`
    - `:telemetry_interval` - Interval in ms for the periodic `:status` event (default: 5_000)
    - `:telemetry_sample_rate` - Per-call `:get_channel` telemetry: `1` = emit every
      call (default), `0` = never, `N` = emit ~1-in-N (default: 1)
  - `:connection` - Connection-specific settings
    - `:keepalive` - Keepalive interval in milliseconds (default: 30_000)
    - `:health_check` - Whether to enable connection health checks (default: true)
    - `:ping_interval` - Interval to send ping to keep connection warm (default: 25_000)

  ## Examples

  ### Production Configuration

      config = %GrpcConnectionPool.Config{
        endpoint: %{
          type: :production,
          host: "api.example.com",
          port: 443,
          ssl: []
        },
        pool: %{
          size: 10,
          name: MyApp.GrpcPool
        }
      }

  ### Custom Endpoint Configuration

      config = %GrpcConnectionPool.Config{
        endpoint: %{
          type: :test,
          host: "localhost",
          port: 9090
        },
        pool: %{
          size: 3
        }
      }

  ### Using Custom Credentials

      config = %GrpcConnectionPool.Config{
        endpoint: %{
          type: :production,
          host: "secure-api.example.com", 
          port: 443,
          credentials: GRPC.Credential.new(ssl: [
            verify: :verify_peer,
            cacertfile: "/path/to/ca.pem"
          ])
        }
      }

  ### Using Interceptors

      config = %GrpcConnectionPool.Config{
        endpoint: %{
          type: :production,
          host: "api.example.com",
          port: 443,
          interceptors: [MyApp.LoggingInterceptor, MyApp.AuthInterceptor]
        }
      }

  """

  @type endpoint_type :: atom()

  @type endpoint_config :: %{
          type: endpoint_type(),
          host: String.t() | nil,
          port: pos_integer() | nil,
          ssl: keyword() | boolean() | nil,
          credentials: GRPC.Credential.t() | nil,
          retry_config: retry_config() | nil,
          interceptors: [module()] | nil
        }

  @type pool_config :: %{
          size: pos_integer(),
          name: atom() | nil,
          telemetry_interval: pos_integer(),
          telemetry_sample_rate: non_neg_integer(),
          strategy: atom()
        }

  @type connection_config :: %{
          keepalive: pos_integer(),
          health_check: boolean(),
          ping_interval: pos_integer() | nil,
          suppress_connection_errors: boolean(),
          backoff_min: pos_integer(),
          backoff_max: pos_integer(),
          max_reconnect_attempts: pos_integer()
        }

  @type retry_config :: %{
          max_attempts: pos_integer(),
          base_delay: pos_integer(),
          max_delay: pos_integer()
        }

  @type t :: %__MODULE__{
          endpoint: endpoint_config(),
          pool: pool_config(),
          connection: connection_config()
        }

  defstruct endpoint: %{
              type: :production,
              host: nil,
              port: nil,
              ssl: nil,
              credentials: nil,
              retry_config: nil,
              interceptors: nil
            },
            pool: %{
              size: 5,
              name: nil,
              telemetry_interval: 5_000,
              strategy: :round_robin
            },
            connection: %{
              keepalive: 30_000,
              health_check: true,
              ping_interval: 25_000,
              suppress_connection_errors: false,
              backoff_min: 1_000,
              backoff_max: 30_000,
              max_reconnect_attempts: 5
            }

  @doc """
  Creates a new pool configuration from keyword options or environment variables.

  ## Options

  See module documentation for available options.

  ## Examples

      # From explicit options
      {:ok, config} = GrpcConnectionPool.Config.new([
        endpoint: [type: :test, host: "localhost", port: 9090],
        pool: [size: 8, name: MyApp.CustomPool]
      ])

      # From application environment
      {:ok, config} = GrpcConnectionPool.Config.from_env(:my_app)

  """
  @spec new(keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(opts \\ []) do
    config = %__MODULE__{
      endpoint: build_endpoint_config(opts[:endpoint] || []),
      pool: build_pool_config(opts[:pool] || []),
      connection: build_connection_config(opts[:connection] || [])
    }

    {:ok, config}
  rescue
    error -> {:error, "Invalid configuration: #{Exception.message(error)}"}
  end

  @doc """
  Creates a pool configuration from application environment variables.

  Looks for configuration under the specified application key:

      config :my_app, GrpcConnectionPool,
        endpoint: [type: :production, host: "api.example.com", port: 443],
        pool: [size: 10],
        connection: [keepalive: 45_000]

  """
  @spec from_env(atom(), atom()) :: {:ok, t()} | {:error, String.t()}
  def from_env(app, key \\ GrpcConnectionPool) do
    case Application.get_env(app, key) do
      nil -> new([])
      config when is_list(config) -> new(config)
      _ -> {:error, "Invalid configuration format in application environment"}
    end
  end

  @doc """
  Creates a production configuration with SSL.

  ## Options

  - `:host` - Hostname (required)
  - `:port` - Port (default: 443)
  - `:pool_size` - Number of connections (default: 5)
  - `:pool_name` - Pool name (default: auto-generated)
  - `:ssl` - SSL configuration (default: [])

  """
  @spec production(keyword()) :: {:ok, t()} | {:error, String.t()}
  def production(opts \\ []) do
    host = opts[:host]

    if is_nil(host) do
      {:error, "host is required for production configuration"}
    else
      new(
        endpoint: [
          type: :production,
          host: host,
          port: opts[:port] || 443,
          ssl: opts[:ssl] || default_production_ssl()
        ],
        pool: [
          size: opts[:pool_size] || 5,
          name: opts[:pool_name]
        ]
      )
    end
  end

  @doc """
  Default TLS options for production endpoints: verify the peer certificate
  against the system CA store and check the hostname.

  On OTP 25+ this returns a fully-verifying config. On older OTP (no
  `:public_key.cacerts_get/0`) it returns `[]` and logs a warning, since there
  is no portable system-CA accessor — set `:ssl` explicitly in that case.
  """
  @spec default_production_ssl() :: keyword()
  def default_production_ssl do
    if function_exported?(:public_key, :cacerts_get, 0) do
      [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 3,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    else
      require Logger

      Logger.warning(
        "grpc_connection_pool: OTP < 25 has no system CA accessor; production TLS " <>
          "will use library defaults. Set :ssl explicitly (e.g. cacertfile:) to verify peers."
      )

      []
    end
  end

  @doc """
  Creates a local/test configuration without SSL.

  ## Options

  - `:host` - Hostname (default: "localhost")
  - `:port` - Port (default: 9090)
  - `:pool_size` - Number of connections (default: 3)
  - `:pool_name` - Pool name (default: auto-generated)

  """
  @spec local(keyword()) :: {:ok, t()}
  def local(opts \\ []) do
    new(
      endpoint: [
        type: :local,
        host: opts[:host] || "localhost",
        port: opts[:port] || 9090,
        retry_config: [
          max_attempts: 3,
          base_delay: 1000,
          max_delay: 5000
        ]
      ],
      pool: [
        size: opts[:pool_size] || 3,
        name: opts[:pool_name]
      ]
    )
  end

  @doc """
  Gets the gRPC connection endpoint from the configuration.

  Returns a tuple of `{host, port, options}` suitable for `GRPC.Stub.connect/3`.
  """
  @spec get_endpoint(t()) :: {String.t(), pos_integer(), keyword()}
  def get_endpoint(%__MODULE__{endpoint: endpoint, connection: connection}) do
    opts = build_connection_opts(endpoint, connection)
    {endpoint.host, endpoint.port, opts}
  end

  @doc """
  Gets the retry configuration for connection attempts.
  """
  @spec get_retry_config(t()) :: retry_config() | nil
  def get_retry_config(%__MODULE__{endpoint: endpoint}) do
    endpoint.retry_config
  end

  # Private functions

  defp build_endpoint_config(opts) do
    type = opts[:type] || :production

    base = %{
      type: type,
      host: opts[:host],
      port: opts[:port],
      ssl: opts[:ssl],
      credentials: opts[:credentials],
      retry_config: build_retry_config(opts[:retry_config] || []),
      interceptors: opts[:interceptors]
    }

    validate_endpoint_config!(base)
    validate_production_tls!(opts, base)
    base
  end

  defp build_pool_config(opts) do
    %{
      size: opts[:size] || 5,
      name: opts[:name],
      telemetry_interval: opts[:telemetry_interval] || 5_000,
      # Per-call get_channel telemetry sampling: 1 = emit every call (default,
      # backward compatible), 0 = never, N = emit ~1-in-N. High-throughput
      # callers can set 0 and rely on the periodic :status event instead.
      telemetry_sample_rate: opts[:telemetry_sample_rate] || 1,
      strategy: opts[:strategy] || :round_robin
    }
  end

  defp build_connection_config(opts) do
    %{
      keepalive: opts[:keepalive] || 30_000,
      health_check: opts[:health_check] != false,
      ping_interval: opts[:ping_interval] || 25_000,
      suppress_connection_errors: opts[:suppress_connection_errors] || false,
      backoff_min: opts[:backoff_min] || 1_000,
      backoff_max: opts[:backoff_max] || 30_000,
      max_reconnect_attempts: opts[:max_reconnect_attempts] || 5
    }
  end

  defp build_retry_config([]), do: nil

  defp build_retry_config(opts) do
    %{
      max_attempts: opts[:max_attempts] || 3,
      base_delay: opts[:base_delay] || 1000,
      max_delay: opts[:max_delay] || 5000
    }
  end

  defp build_connection_opts(endpoint, connection) do
    base_opts = [
      adapter_opts: [
        http2_opts: %{keepalive: connection.keepalive}
      ]
    ]

    # Add credentials if specified
    cred_opts =
      cond do
        endpoint.credentials -> [cred: endpoint.credentials]
        endpoint.ssl -> [cred: GRPC.Credential.new(ssl: endpoint.ssl)]
        true -> []
      end

    # Add interceptors if specified
    interceptor_opts =
      if endpoint.interceptors != nil and endpoint.interceptors != [] do
        [interceptors: endpoint.interceptors]
      else
        []
      end

    base_opts ++ cred_opts ++ interceptor_opts
  end

  defp validate_endpoint_config!(%{host: nil}),
    do: raise(ArgumentError, "host is required for endpoint configuration")

  defp validate_endpoint_config!(%{port: nil}),
    do: raise(ArgumentError, "port is required for endpoint configuration")

  defp validate_endpoint_config!(_), do: :ok

  # An *explicit* :production endpoint with neither :ssl nor :credentials would
  # silently connect over plaintext h2c. Refuse it — the caller must opt into
  # TLS (`ssl: [...]` / `credentials:`) or use `type: :local` for plaintext.
  # Only fires when the caller explicitly passes `type: :production`; a defaulted
  # type stays permissive for local/test usage.
  defp validate_production_tls!(opts, %{ssl: nil, credentials: nil}) do
    if opts[:type] == :production do
      raise(
        ArgumentError,
        "production endpoint requires TLS: set :ssl (e.g. ssl: GrpcConnectionPool.Config.default_production_ssl()) " <>
          "or :credentials, or use type: :local for an explicit plaintext connection"
      )
    end

    :ok
  end

  defp validate_production_tls!(_opts, _base), do: :ok
end
