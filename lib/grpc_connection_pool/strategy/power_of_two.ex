defmodule GrpcConnectionPool.Strategy.PowerOfTwo do
  @moduledoc """
  Power-of-two-choices with least-recently-used tiebreak.

  Picks two random channel indices and returns the one that was
  least recently used (based on a timestamp stored in ETS alongside
  each channel). This provides better load distribution than pure
  random under uneven workloads.

  Each channel slot stores `{:channel, index} => {channel, last_used_at}`
  in ETS. The `last_used_at` is updated on each selection.
  """

  @behaviour GrpcConnectionPool.Strategy

  @impl true
  def init(_pool_name, _pool_size) do
    :ok
  end

  @impl true
  def select(_state, channel_count, ets_table) do
    if channel_count == 1 do
      {:ok, 0}
    else
      i = :rand.uniform(channel_count) - 1
      j = pick_different(i, channel_count)

      # Compare last_used timestamps
      ts_i = get_last_used(ets_table, i)
      ts_j = get_last_used(ets_table, j)

      chosen = if ts_i <= ts_j, do: i, else: j

      # Update last_used for the chosen channel
      :ets.update_element(ets_table, {:channel, chosen}, {3, System.monotonic_time()})

      {:ok, chosen}
    end
  end

  defp pick_different(i, count) do
    j = :rand.uniform(count) - 1
    if j == i, do: rem(i + 1, count), else: j
  end

  defp get_last_used(ets_table, index) do
    case :ets.lookup(ets_table, {:channel, index}) do
      [{_, _channel, last_used}] -> last_used
      _ -> 0
    end
  end
end
