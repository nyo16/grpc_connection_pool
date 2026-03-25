defmodule GrpcConnectionPool.Strategy.RoundRobin do
  @moduledoc """
  Lock-free round-robin channel selection using `:atomics`.

  This is the default strategy. It uses an atomic counter for
  contention-free round-robin distribution with zero ETS writes
  in the hot path.
  """

  @behaviour GrpcConnectionPool.Strategy

  @impl true
  def init(_pool_name, _pool_size) do
    :atomics.new(1, signed: true)
  end

  @impl true
  def select(atomics_ref, channel_count, _ets_table) do
    index = :atomics.add_get(atomics_ref, 1, 1)
    {:ok, rem(abs(index), channel_count)}
  end
end
