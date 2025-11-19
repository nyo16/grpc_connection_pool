defmodule GrpcConnectionPool.MixProject do
  use Mix.Project

  @version "0.1.3"
  @source_url "https://github.com/nyo16/grpc_connection_pool"

  def project do
    [
      app: :grpc_connection_pool,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      package: package(),
      description: description(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.cobertura": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp description do
    """
    A flexible and robust gRPC connection pooling library for Elixir using Poolex.
    Features environment-agnostic configuration, connection warming, health monitoring,
    and automatic retry logic with exponential backoff.
    """
  end

  defp package do
    [
      description: description(),
      files: ~w(lib .formatter.exs mix.exs README* LICENSE*),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Documentation" => "https://hexdocs.pm/grpc_connection_pool"
      },
      maintainers: ["Niko Maroulis"]
    ]
  end

  defp docs do
    [
      main: "GrpcConnectionPool",
      source_url: @source_url,
      extras: [
        "README.md": [title: "Overview"],
      ],
      groups_for_modules: [
        "Core": [GrpcConnectionPool, GrpcConnectionPool.Pool],
        "Configuration": [GrpcConnectionPool.Config],
        "Internal": [GrpcConnectionPool.Worker]
      ]
    ]
  end

  defp deps do
    [
      {:poolex, "~> 1.4.2"},
      {:grpc, "~> 0.11.5", override: true},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      # Optional for authentcating with GCP
      {:goth, "~> 1.4", only: :test},
      # Optional dependencies for testing and development

      {:googleapis_proto_ex, "~> 0.3.0", only: :test}
    ]
  end
end
