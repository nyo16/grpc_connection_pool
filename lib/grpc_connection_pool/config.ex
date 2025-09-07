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
  - `:pool` - Pool configuration
    - `:size` - Number of connections in pool (default: 5)
    - `:name` - Pool name (default: auto-generated)
    - `:checkout_timeout` - Timeout for checking out connections (default: 15_000)
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

  """

  @type endpoint_type :: atom()

  @type endpoint_config :: %{
          type: endpoint_type(),
          host: String.t() | nil,
          port: pos_integer() | nil,
          ssl: keyword() | boolean() | nil,
          credentials: GRPC.Credential.t() | nil,
          retry_config: retry_config() | nil
        }

  @type pool_config :: %{
          size: pos_integer(),
          name: atom() | nil,
          checkout_timeout: pos_integer()
        }

  @type connection_config :: %{
          keepalive: pos_integer(),
          health_check: boolean(),
          ping_interval: pos_integer() | nil,
          suppress_connection_errors: boolean()
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
              retry_config: nil
            },
            pool: %{
              size: 5,
              name: nil,
              checkout_timeout: 15_000
            },
            connection: %{
              keepalive: 30_000,
              health_check: true,
              ping_interval: 25_000,
              suppress_connection_errors: false
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
    try do
      config = %__MODULE__{
        endpoint: build_endpoint_config(opts[:endpoint] || []),
        pool: build_pool_config(opts[:pool] || []),
        connection: build_connection_config(opts[:connection] || [])
      }

      {:ok, config}
    rescue
      error -> {:error, "Invalid configuration: #{Exception.message(error)}"}
    end
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
      new([
        endpoint: [
          type: :production,
          host: host,
          port: opts[:port] || 443,
          ssl: opts[:ssl] || []
        ],
        pool: [
          size: opts[:pool_size] || 5,
          name: opts[:pool_name]
        ]
      ])
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
    new([
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
    ])
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
      retry_config: build_retry_config(opts[:retry_config] || [])
    }

    validate_endpoint_config!(base)
    base
  end

  defp build_pool_config(opts) do
    %{
      size: opts[:size] || 5,
      name: opts[:name],
      checkout_timeout: opts[:checkout_timeout] || 15_000
    }
  end

  defp build_connection_config(opts) do
    %{
      keepalive: opts[:keepalive] || 30_000,
      health_check: opts[:health_check] != false,
      ping_interval: opts[:ping_interval] || 25_000,
      suppress_connection_errors: opts[:suppress_connection_errors] || false
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

    base_opts ++ cred_opts
  end

  defp validate_endpoint_config!(%{host: nil}),
    do: raise(ArgumentError, "host is required for endpoint configuration")

  defp validate_endpoint_config!(%{port: nil}),
    do: raise(ArgumentError, "port is required for endpoint configuration")

  defp validate_endpoint_config!(_), do: :ok
end