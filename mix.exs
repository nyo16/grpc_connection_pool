defmodule GrpcConnectionPool.MixProject do
  use Mix.Project

  @version "0.4.0"
  @source_url "https://github.com/nyo16/grpc_connection_pool"

  def project do
    [
      app: :grpc_connection_pool,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      docs: docs(),
      package: package(),
      description: description(),
      source_url: @source_url,
      test_coverage: [tool: ExCoveralls],
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        plt_add_apps: [:mix, :ex_unit]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :public_key, :ssl]
    ]
  end

  # test/support holds shared test helpers (e.g. the Cowboy h2c server) compiled
  # only in the test environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

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
        "Documentation" => "https://hexdocs.pm/grpc_connection_pool",
        "Changelog" => "#{@source_url}/blob/master/CHANGELOG.md"
      },
      maintainers: ["Niko Maroulis"]
    ]
  end

  defp docs do
    [
      main: "GrpcConnectionPool",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: [
        "README.md": [title: "Overview"],
        "CHANGELOG.md": [title: "Changelog"],
        LICENSE: [title: "License"]
      ],
      groups_for_modules: [
        Core: [GrpcConnectionPool, GrpcConnectionPool.Pool],
        Configuration: [GrpcConnectionPool.Config],
        Strategies: [
          GrpcConnectionPool.Strategy,
          GrpcConnectionPool.Strategy.RoundRobin,
          GrpcConnectionPool.Strategy.Random,
          GrpcConnectionPool.Strategy.PowerOfTwo
        ],
        Internal: [
          GrpcConnectionPool.Worker,
          GrpcConnectionPool.PoolState,
          GrpcConnectionPool.Backoff
        ]
      ]
    ]
  end

  defp deps do
    [
      {:backoff, "~> 1.1"},
      {:grpc, "~> 1.0"},
      # grpc >= 1.0 makes gun optional; we use the default Gun adapter, so require it explicitly
      {:gun, "~> 2.2"},
      {:telemetry, "~> 1.0"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:benchee, "~> 1.0", only: :dev},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      # Optional for authentcating with GCP
      {:goth, "~> 1.4", only: :test},
      # Optional dependencies for testing and development

      {:googleapis_proto_ex, "~> 0.4.0", only: :test},
      # grpc >= 1.0 is client-only (no GRPC.Server); tests stand up a bare HTTP/2
      # listener with Cowboy to exercise the real connect path.
      {:cowboy, "~> 2.14", only: :test}
    ]
  end
end
