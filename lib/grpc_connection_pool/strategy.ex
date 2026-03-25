defmodule GrpcConnectionPool.Strategy do
  @moduledoc """
  Behaviour for connection selection strategies.

  A strategy determines which channel index to select when `get_channel/1`
  is called. Built-in strategies:

  - `:round_robin` — Lock-free atomics-based round-robin (default)
  - `:random` — Random selection, good for avoiding hot-spotting
  - `:power_of_two` — Power-of-two-choices with least-recently-used tiebreak

  ## Custom Strategies

  Implement this behaviour to create a custom strategy:

      defmodule MyApp.WeightedStrategy do
        @behaviour GrpcConnectionPool.Strategy

        @impl true
        def init(_pool_name, _pool_size), do: %{}

        @impl true
        def select(_state, channel_count, _ets_table) do
          # Custom selection logic
          {:ok, :rand.uniform(channel_count) - 1}
        end
      end

  Then configure it:

      config = GrpcConnectionPool.Config.new(
        pool: [strategy: MyApp.WeightedStrategy]
      )

  """

  @type state :: term()

  @doc """
  Initialize strategy state for a pool.

  Called once during pool startup. The returned state is stored in
  `:persistent_term` and passed to `select/3` on each call.
  """
  @callback init(pool_name :: atom(), pool_size :: pos_integer()) :: state()

  @doc """
  Select a channel index from the pool.

  Must return an index in the range `0..channel_count-1`.
  Called on every `get_channel` invocation — must be fast.
  """
  @callback select(state(), channel_count :: pos_integer(), ets_table :: atom()) ::
              {:ok, non_neg_integer()}

  @doc false
  def resolve(:round_robin), do: GrpcConnectionPool.Strategy.RoundRobin
  def resolve(:random), do: GrpcConnectionPool.Strategy.Random
  def resolve(:power_of_two), do: GrpcConnectionPool.Strategy.PowerOfTwo
  def resolve(module) when is_atom(module), do: module
end
