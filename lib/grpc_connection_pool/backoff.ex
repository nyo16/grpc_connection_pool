defmodule GrpcConnectionPool.Backoff do
  @moduledoc """
  Exponential backoff with jitter for connection retry logic.

  This module wraps the Erlang `:backoff` library to provide consistent
  retry behavior across all connection attempts. The jitter helps prevent
  the thundering herd problem when multiple connections fail simultaneously.

  ## Configuration

  The backoff behavior can be configured with:
  - `:min` - Minimum delay in milliseconds (default: 1000)
  - `:max` - Maximum delay in milliseconds (default: 30000)

  ## Example

      # Initialize backoff state
      state = GrpcConnectionPool.Backoff.new(min: 1000, max: 30_000)

      # On connection failure, get next delay
      {delay_ms, new_state} = GrpcConnectionPool.Backoff.fail(state)
      Process.send_after(self(), :reconnect, delay_ms)

      # On successful connection, reset backoff
      new_state = GrpcConnectionPool.Backoff.succeed(state)

  """

  @type t :: :backoff.backoff()

  @doc """
  Creates a new backoff state with exponential backoff and jitter.

  ## Options

  - `:min` - Minimum delay in milliseconds (default: 1000)
  - `:max` - Maximum delay in milliseconds (default: 30000)

  ## Examples

      iex> state = GrpcConnectionPool.Backoff.new(min: 1000, max: 30_000)
      iex> is_tuple(state)
      true

  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    min = Keyword.get(opts, :min, 1000)
    max = Keyword.get(opts, :max, 30_000)

    :backoff.init(min, max)
    |> :backoff.type(:jitter)
  end

  @doc """
  Increments the backoff delay after a connection failure.

  Returns a tuple with the delay in milliseconds and the updated backoff state.

  ## Examples

      state = GrpcConnectionPool.Backoff.new(min: 1000, max: 30_000)
      {delay, new_state} = GrpcConnectionPool.Backoff.fail(state)
      # delay will be between 1000 and 2000 (with jitter)

  """
  @spec fail(t()) :: {non_neg_integer(), t()}
  def fail(state) do
    {delay, new_state} = :backoff.fail(state)
    {delay, new_state}
  end

  @doc """
  Resets the backoff state after a successful connection.

  This ensures that the next failure will start with the minimum delay again.

  ## Examples

      state = GrpcConnectionPool.Backoff.new(min: 1000, max: 30_000)
      {_delay, failed_state} = GrpcConnectionPool.Backoff.fail(state)
      reset_state = GrpcConnectionPool.Backoff.succeed(failed_state)
      # reset_state is back to initial state

  """
  @spec succeed(t()) :: t()
  def succeed(state) do
    {_, new_state} = :backoff.succeed(state)
    new_state
  end
end
