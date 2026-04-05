defmodule FireBird.Cleaner do
  @moduledoc """
  Periodic cleanup of webhook deduplication and rate limiting ETS tables.

  Deletes entries older than `:ttl_ms` at every `:interval_ms` tick.
  Without this process the dedup and rate limit tables grow without bound.

  ## Options
    - `:dedup_table` — Dedup ETS table name (default: `FireBird.Webhook`)
    - `:rate_limit_table` — Rate limit ETS table name (optional, nil disables)
    - `:ttl_ms` — Entry time-to-live in milliseconds (default: 86_400_000 = 24 h)
    - `:interval_ms` — Cleanup interval in milliseconds (default: 3_600_000 = 1 h)
  """

  use GenServer

  require Logger

  defstruct [:dedup_table, :rate_limit_table, :ttl_ms, :interval_ms, :timer_ref]

  @default_ttl_ms 86_400_000
  @default_interval_ms 3_600_000

  @doc "Starts the dedup cleaner."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Deletes dedup entries older than `ttl_ms` from `table`.

  Dedup entries have the format `{key, timestamp}`.
  Returns the number of deleted entries, or `0` if the table does not exist.
  """
  @spec cleanup(atom(), non_neg_integer()) :: non_neg_integer()
  def cleanup(table, ttl_ms) do
    case :ets.whereis(table) do
      :undefined ->
        0

      _ref ->
        cutoff = System.monotonic_time(:millisecond) - ttl_ms

        match_spec = [
          {{:_, :"$1"}, [{:<, :"$1", cutoff}], [true]}
        ]

        :ets.select_delete(table, match_spec)
    end
  end

  @doc """
  Deletes rate limit entries older than `ttl_ms` from `table`.

  Rate limit entries have the format `{ip, count, window_start_ms}`.
  Returns the number of deleted entries, or `0` if the table does not exist.
  """
  @spec cleanup_rate_limit(atom(), non_neg_integer()) :: non_neg_integer()
  def cleanup_rate_limit(table, ttl_ms) do
    case :ets.whereis(table) do
      :undefined ->
        0

      _ref ->
        cutoff = System.monotonic_time(:millisecond) - ttl_ms

        match_spec = [
          {{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}
        ]

        :ets.select_delete(table, match_spec)
    end
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    dedup_table = Keyword.get(opts, :dedup_table, FireBird.Webhook)
    rate_limit_table = Keyword.get(opts, :rate_limit_table)
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)

    state = %__MODULE__{
      dedup_table: dedup_table,
      rate_limit_table: rate_limit_table,
      ttl_ms: ttl_ms,
      interval_ms: interval_ms
    }

    timer_ref = schedule_cleanup(interval_ms)
    {:ok, %{state | timer_ref: timer_ref}}
  end

  @impl GenServer
  def handle_info(:cleanup, state) do
    dedup_deleted = cleanup(state.dedup_table, state.ttl_ms)

    rate_deleted =
      if state.rate_limit_table do
        cleanup_rate_limit(state.rate_limit_table, state.ttl_ms)
      else
        0
      end

    total = dedup_deleted + rate_deleted

    if total > 0 do
      Logger.info("Cleaner: deleted #{total} expired entries")
    end

    timer_ref = schedule_cleanup(state.interval_ms)
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  def handle_info(msg, state) do
    Logger.debug("Cleaner: unexpected message #{inspect(msg)}")
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    :ok
  end

  defp schedule_cleanup(interval), do: Process.send_after(self(), :cleanup, interval)
end
