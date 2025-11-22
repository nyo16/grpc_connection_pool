defmodule GrpcConnectionPool.MixProject do
  use Mix.Project

  @version "0.2.1"
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
      test_coverage: [tool: ExCoveralls]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.cobertura": :test
      ]
    ]
  end

  defp description do
    """
    A flexible and robust gRPC connection pooling library for Elixir.
    Features environment-agnostic configuration, connection warming, health monitoring,
    and automatic retry logic with exponential backoff and jitter.
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
        "LICENSE": [title: "License"]
      ],
      groups_for_modules: [
        Core: [GrpcConnectionPool, GrpcConnectionPool.Pool],
        Configuration: [GrpcConnectionPool.Config],
        Internal: [GrpcConnectionPool.Worker]
      ]
    ]
  end

  defp deps do
    [
      {:backoff, "~> 1.1"},
      {:grpc, "~> 0.11.5"},
      {:telemetry, "~> 1.0"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      # Optional for authentcating with GCP
      {:goth, "~> 1.4", only: :test},
      # Optional dependencies for testing and development

      {:googleapis_proto_ex, "~> 0.3.3", only: :test}
    ]
  end
end
