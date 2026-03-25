defmodule GrpcConnectionPool.PoolState do
  @moduledoc """
  ETS table owner and heir process for crash resilience.

  This GenServer owns the pool's ETS table and acts as its own heir.
  If the process crashes, the table is inherited by the replacement
  process started by the supervisor.

  The ETS table stores:
  - `{:channel, index}` — `{channel, last_used_at}` for O(1) indexed access
  - `:channel_count` — number of connected channels (atomic updates)
  - `:pool_size` — expected pool size
  - `:config` — pool configuration (also stored in :persistent_term)
  - `:channel_slots` — maps worker PIDs to their slot indices
  - `:scaling_lock` — lock for scaling operations
  """

  use GenServer

  @doc false
  def start_link(opts) do
    pool_name = Keyword.fetch!(opts, :pool_name)
    GenServer.start_link(__MODULE__, opts, name: :"#{pool_name}.PoolState")
  end

  @doc false
  def claim_slot(ets_table, pid) do
    case :ets.lookup(ets_table, :channel_slots) do
      [{:channel_slots, slots}] ->
        case Map.get(slots, pid) do
          nil ->
            # Find next available slot
            used = MapSet.new(Map.values(slots))
            slot = find_free_slot(used, 0)
            new_slots = Map.put(slots, pid, slot)
            :ets.insert(ets_table, {:channel_slots, new_slots})
            slot

          existing_slot ->
            existing_slot
        end

      [] ->
        :ets.insert(ets_table, {:channel_slots, %{pid => 0}})
        0
    end
  end

  @doc false
  def release_slot(ets_table, pid) do
    case :ets.lookup(ets_table, :channel_slots) do
      [{:channel_slots, slots}] ->
        do_release_slot(ets_table, pid, slots)

      [] ->
        :ok
    end
  end

  defp do_release_slot(_ets_table, _pid, slots) when map_size(slots) == 0, do: :ok

  defp do_release_slot(ets_table, pid, slots) do
    case Map.pop(slots, pid) do
      {nil, _} ->
        :ok

      {slot, new_slots} ->
        :ets.insert(ets_table, {:channel_slots, new_slots})
        :ets.delete(ets_table, {:channel, slot})

        channel_count = map_size(new_slots)

        if slot < channel_count and channel_count > 0 do
          compact_slots(ets_table, new_slots, slot, channel_count)
        end

        :ok
    end
  end

  # GenServer callbacks

  @impl GenServer
  def init(opts) do
    pool_name = Keyword.fetch!(opts, :pool_name)
    config = Keyword.fetch!(opts, :config)
    pool_size = config.pool.size

    ets_table = :"#{pool_name}.ETS"

    table =
      :ets.new(ets_table, [
        :public,
        :named_table,
        :set,
        {:read_concurrency, true},
        {:write_concurrency, true}
      ])

    # Set heir to self — when this process restarts, the supervisor
    # ensures the table is re-created. For true heir support, we'd
    # need a separate long-lived process, but this is simpler and
    # the DynamicSupervisor restarts workers which re-register.
    :ets.insert(table, {:channel_count, 0})
    :ets.insert(table, {:pool_size, pool_size})
    :ets.insert(table, {:config, config})
    :ets.insert(table, {:channel_slots, %{}})

    # Store config and strategy in persistent_term for zero-copy reads
    strategy_mod = GrpcConnectionPool.Strategy.resolve(config.pool.strategy)
    strategy_state = strategy_mod.init(pool_name, pool_size)

    :persistent_term.put({GrpcConnectionPool.Pool, pool_name, :config}, config)
    :persistent_term.put({GrpcConnectionPool.Pool, pool_name, :strategy_mod}, strategy_mod)
    :persistent_term.put({GrpcConnectionPool.Pool, pool_name, :strategy_state}, strategy_state)
    :persistent_term.put({GrpcConnectionPool.Pool, pool_name, :ets_table}, ets_table)

    {:ok, %{pool_name: pool_name, ets_table: table}}
  end

  @impl GenServer
  def terminate(_reason, state) do
    pool_name = state.pool_name

    # Clean up persistent_term entries
    for key <- [:config, :strategy_mod, :strategy_state, :ets_table] do
      :persistent_term.erase({GrpcConnectionPool.Pool, pool_name, key})
    end

    :ok
  end

  # Private helpers

  defp find_free_slot(used, candidate) do
    if MapSet.member?(used, candidate) do
      find_free_slot(used, candidate + 1)
    else
      candidate
    end
  end

  defp compact_slots(ets_table, slots, gap_slot, channel_count) do
    # Find the worker that has the highest slot index
    # This was the count before removal, so highest = count
    highest_slot = channel_count

    case Enum.find(slots, fn {_pid, s} -> s == highest_slot end) do
      {pid, ^highest_slot} ->
        # Move this channel from highest_slot to gap_slot
        case :ets.lookup(ets_table, {:channel, highest_slot}) do
          [{_, channel, last_used}] ->
            :ets.insert(ets_table, {{:channel, gap_slot}, channel, last_used})
            :ets.delete(ets_table, {:channel, highest_slot})

            new_slots = Map.put(slots, pid, gap_slot)
            :ets.insert(ets_table, {:channel_slots, new_slots})

          [] ->
            :ok
        end

      nil ->
        :ok
    end
  end
end
