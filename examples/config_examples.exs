# Configuration Examples for GrpcConnectionPool
#
# This file contains various configuration examples for different use cases.
# Copy the relevant examples to your config/config.exs file.

# =============================================================================
# Basic Production Configuration
# =============================================================================

# For a production gRPC service with SSL
config :my_app, GrpcConnectionPool,
  endpoint: [
    type: :production,
    host: "api.example.com",
    port: 443,
    ssl: []  # Use default SSL settings
  ],
  pool: [
    size: 10,
    name: MyApp.GrpcPool
  ],
  connection: [
    keepalive: 30_000,     # Send keepalive every 30 seconds
    ping_interval: 25_000,  # Ping every 25 seconds to keep warm
    health_check: true
  ]

# =============================================================================  
# Local Development Configuration
# =============================================================================

# For local development with a gRPC server (no SSL)
config :my_app, GrpcConnectionPool,
  endpoint: [
    type: :local,
    host: "localhost", 
    port: 9090
  ],
  pool: [
    size: 3,  # Smaller pool for development
    name: MyApp.DevPool
  ]

# =============================================================================
# Test Environment with Emulator
# =============================================================================

# For testing with Google Pub/Sub emulator or similar
config :my_app, GrpcConnectionPool,
  endpoint: [
    type: :test,
    host: "localhost",
    port: 8085,
    retry_config: [
      max_attempts: 3,
      base_delay: 1000,
      max_delay: 5000
    ]
  ],
  pool: [
    size: 2,  # Small pool for tests
    name: MyApp.TestPool
  ],
  connection: [
    ping_interval: nil  # Disable pinging in tests
  ]

# =============================================================================
# Multiple Service Configuration
# =============================================================================

# Configuration for multiple gRPC services
config :my_app, :service_a,
  endpoint: [
    type: :production,
    host: "service-a.example.com",
    port: 443
  ],
  pool: [
    size: 5,
    name: MyApp.ServiceAPool
  ]

config :my_app, :service_b,  
  endpoint: [
    type: :production,
    host: "service-b.example.com", 
    port: 443
  ],
  pool: [
    size: 8,
    name: MyApp.ServiceBPool
  ]

# =============================================================================
# Advanced SSL Configuration  
# =============================================================================

# Custom SSL configuration with client certificates
config :my_app, GrpcConnectionPool,
  endpoint: [
    type: :production,
    host: "secure-api.example.com",
    port: 443,
    credentials: GRPC.Credential.new(ssl: [
      verify: :verify_peer,
      cacertfile: "/path/to/ca.pem",
      certfile: "/path/to/client.pem", 
      keyfile: "/path/to/client-key.pem"
    ])
  ]

# =============================================================================
# Environment-Specific Configuration
# =============================================================================

# Different configurations per environment using Mix.env()
case Mix.env() do
  :prod ->
    config :my_app, GrpcConnectionPool,
      endpoint: [
        type: :production,
        host: "api.example.com",
        port: 443
      ],
      pool: [size: 20]  # Large pool for production
      
  :dev ->
    config :my_app, GrpcConnectionPool,
      endpoint: [
        type: :local,
        host: "localhost", 
        port: 9090
      ],
      pool: [size: 3]   # Small pool for development
      
  :test ->
    config :my_app, GrpcConnectionPool,
      endpoint: [
        type: :test,
        host: "localhost",
        port: 8085
      ],
      pool: [size: 1],  # Minimal pool for tests
      connection: [
        ping_interval: nil  # No pinging needed in tests
      ]
end

# =============================================================================
# Usage in Application Module
# =============================================================================

# In your lib/my_app/application.ex:
#
# defmodule MyApp.Application do
#   use Application
#   
#   def start(_type, _args) do
#     # Single pool from config
#     {:ok, config} = GrpcConnectionPool.Config.from_env(:my_app)
#     
#     children = [
#       # Your other processes...
#       {GrpcConnectionPool, config},
#     ]
#     
#     # Or multiple pools:
#     # {:ok, service_a_config} = GrpcConnectionPool.Config.from_env(:my_app, :service_a)  
#     # {:ok, service_b_config} = GrpcConnectionPool.Config.from_env(:my_app, :service_b)
#     #
#     # children = [
#     #   {GrpcConnectionPool, service_a_config},
#     #   {GrpcConnectionPool, service_b_config}
#     # ]
#     
#     opts = [strategy: :one_for_one, name: MyApp.Supervisor]
#     Supervisor.start_link(children, opts)
#   end
# end

# =============================================================================
# Runtime Configuration (config/runtime.exs)
# =============================================================================

# For configuration that needs to be determined at runtime:
#
# import Config
#
# if config_env() == :prod do
#   # Get configuration from environment variables
#   grpc_host = System.get_env("GRPC_HOST") || "api.example.com"
#   grpc_port = System.get_env("GRPC_PORT", "443") |> String.to_integer()
#   pool_size = System.get_env("GRPC_POOL_SIZE", "10") |> String.to_integer()
#   
#   config :my_app, GrpcConnectionPool,
#     endpoint: [
#       type: :production,
#       host: grpc_host,
#       port: grpc_port
#     ],
#     pool: [size: pool_size]
# end