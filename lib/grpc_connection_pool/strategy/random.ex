defmodule GrpcConnectionPool.Strategy.Random do
  @moduledoc """
  Random channel selection.

  Selects a random channel on each call. This is useful when callers
  are correlated (e.g., batch jobs) and round-robin would cause
  hot-spotting on a single connection.
  """

  @behaviour GrpcConnectionPool.Strategy

  @impl true
  def init(_pool_name, _pool_size) do
    :ok
  end

  @impl true
  def select(_state, channel_count, _ets_table) do
    {:ok, :rand.uniform(channel_count) - 1}
  end
end
