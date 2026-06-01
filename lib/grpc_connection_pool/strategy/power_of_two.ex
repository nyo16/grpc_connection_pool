defmodule GrpcConnectionPool.Strategy.PowerOfTwo do
  @moduledoc """
  Power-of-two-choices with a least-frequently-used tiebreak.

  Picks two distinct random channel indices and returns the one with the lower
  selection count, then increments that count. This spreads load more evenly
  than pure random under skewed workloads.

  Load is tracked in a lock-free `:atomics` array (one counter per slot) rather
  than in ETS, so selection performs **no ETS read or write** in the hot path —
  avoiding the write-lock contention that an `:ets.update_element` on every
  call would cause under concurrency.

  ## Sizing and scaling

  The atomics array is fixed-size at creation. It is sized to
  `max(pool_size, max_slots)` where `max_slots` defaults to `1024` and is
  configurable:

      config :grpc_connection_pool, power_of_two_max_slots: 2048

  If the pool ever scales beyond the array size, `select/3` falls back to a
  pure power-of-two-choices pick (no counter) for the out-of-range indices, so
  it stays correct (never crashes) — it just loses the LFU signal for those
  extra slots.
  """

  @behaviour GrpcConnectionPool.Strategy

  @default_max_slots 1024

  @impl true
  def init(_pool_name, pool_size) do
    max_slots =
      Application.get_env(:grpc_connection_pool, :power_of_two_max_slots, @default_max_slots)

    size = max(pool_size, max_slots)
    {:atomics.new(size, signed: false), size}
  end

  @impl true
  def select({_ref, _size}, 1, _ets_table), do: {:ok, 0}

  def select({ref, size}, channel_count, _ets_table) do
    i = :rand.uniform(channel_count) - 1
    j = pick_different(i, channel_count)

    if i < size and j < size do
      ci = :atomics.get(ref, i + 1)
      cj = :atomics.get(ref, j + 1)
      chosen = if ci <= cj, do: i, else: j
      :atomics.add(ref, chosen + 1, 1)
      {:ok, chosen}
    else
      # Scaled beyond the counter array — pure P2C fallback, no LFU signal.
      {:ok, i}
    end
  end

  defp pick_different(i, count) do
    j = :rand.uniform(count) - 1
    if j == i, do: rem(i + 1, count), else: j
  end
end
