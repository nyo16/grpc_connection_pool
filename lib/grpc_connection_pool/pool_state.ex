defmodule GrpcConnectionPool.PoolState do
  @moduledoc """
  ETS table owner and serializer for slot assignment.

  This GenServer owns the pool's ETS table. The table is `:public` so the
  hot path (`Pool.get_channel/1`) can read it lock-free, but every **write**
  to the channel-slot layout (claiming/releasing a slot, inserting/removing a
  channel, and the `:channel_count` increment/decrement) is funneled through
  this process via `register_channel/3` and `unregister_channel/2`. Because a
  single GenServer processes those calls one at a time, concurrent worker
  connects/disconnects can never interleave a read-modify-write on the slot
  map — slots stay a contiguous `0..channel_count-1` range and the count
  always matches the number of populated `{:channel, index}` entries.

  > Note: the table is **not** crash-resilient. It has no `:heir`, so if this
  > process dies the `:named_table` is destroyed and re-created empty on
  > restart; workers re-populate it as they reconnect. (A real heir would
  > require a separate long-lived owner process.)

  The ETS table stores:
  - `{:channel, index}` — `{channel, last_used_at}` for O(1) indexed access
  - `:channel_count` — number of connected channels
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

  @doc """
  Registers a worker's channel in a pool slot (serialized).

  Assigns the worker the lowest free slot (or reuses its existing slot),
  inserts the channel into ETS, and bumps `:channel_count`. Returns
  `{:ok, slot_index}`. All mutations happen inside the GenServer so
  concurrent registrations cannot race.
  """
  @spec register_channel(atom(), pid(), term()) :: {:ok, non_neg_integer()}
  def register_channel(pool_name, pid, channel) do
    GenServer.call(:"#{pool_name}.PoolState", {:register_channel, pid, channel})
  end

  @doc """
  Releases a worker's slot and decrements `:channel_count` (serialized).

  Removes the worker's channel, compacts the slot array so the remaining
  channels stay contiguous, and decrements the count atomically with the
  slot mutation. No-op if the worker holds no slot.
  """
  @spec unregister_channel(atom(), pid()) :: :ok
  def unregister_channel(pool_name, pid) do
    GenServer.call(:"#{pool_name}.PoolState", {:unregister_channel, pid})
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

    # The table has no :heir — if this process crashes the table is gone
    # and re-created empty on restart; workers re-populate it as they
    # reconnect. See the moduledoc.
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
  def handle_call({:register_channel, pid, channel}, _from, state) do
    ets = state.ets_table
    slots = current_slots(ets)

    case Map.get(slots, pid) do
      nil ->
        used = MapSet.new(Map.values(slots))
        slot = find_free_slot(used, 0)
        new_slots = Map.put(slots, pid, slot)

        :ets.insert(ets, {:channel_slots, new_slots})
        :ets.insert(ets, {{:channel, slot}, channel, System.monotonic_time()})
        :ets.update_counter(ets, :channel_count, {2, 1}, {:channel_count, 0})

        {:reply, {:ok, slot}, state}

      existing_slot ->
        # Worker re-registering (e.g. reconnect without releasing): refresh
        # the channel in place. Do NOT bump the count — the slot is already
        # populated and counted.
        :ets.insert(ets, {{:channel, existing_slot}, channel, System.monotonic_time()})
        {:reply, {:ok, existing_slot}, state}
    end
  end

  def handle_call({:unregister_channel, pid}, _from, state) do
    ets = state.ets_table
    slots = current_slots(ets)

    case Map.pop(slots, pid) do
      {nil, _} ->
        {:reply, :ok, state}

      {slot, new_slots} ->
        :ets.insert(ets, {:channel_slots, new_slots})
        :ets.delete(ets, {:channel, slot})
        new_count = :ets.update_counter(ets, :channel_count, {2, -1, 0, 0})

        # Keep the slot array contiguous: if a non-final slot was freed,
        # move the highest-indexed channel (at slot == new_count) into the
        # gap so indices stay 0..new_count-1.
        if slot < new_count do
          compact_slots(ets, new_slots, slot, new_count)
        end

        {:reply, :ok, state}
    end
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

  defp current_slots(ets_table) do
    case :ets.lookup(ets_table, :channel_slots) do
      [{:channel_slots, slots}] -> slots
      [] -> %{}
    end
  end

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
