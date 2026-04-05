defmodule FireBird.Supervisor do
  @moduledoc """
  `rest_for_one` supervisor for all FireBird processes.

  Children start in order: PubSub → Monitor → Manager → Executor → Cleaner.
  If a child crashes, all children started after it are restarted.

  ## Required options
    - `:client` — `{module, config}` tuple implementing `FireBird.Client`

  ## Optional options
    - `:pubsub_name` — PubSub registry name (default: `FireBird.PubSub`)
    - `:high_watermark` — Monitor high threshold (default: 1_000_000)
    - `:low_watermark` — Monitor low threshold (default: 100_000)
    - `:critical_watermark` — Monitor critical threshold (default: 10_000)
    - `:poll_interval` — Monitor poll interval in ms (default: 30_000)
    - `:invoice_poll_interval` — Manager poll interval in ms (default: 5_000)
    - `:invoice_retention_ms` — Manager terminal invoice TTL (default: 86_400_000)
    - `:invoice_cleanup_interval` — Manager cleanup interval (default: 3_600_000)
    - `:max_concurrent` — Executor concurrency limit (default: 10)
    - `:wal` — Optional `{module, config}` WAL tuple for Executor
    - `:finch` — Optional Finch child spec options (e.g., `[name: :fire_bird_finch]`).
      Starts a Finch pool as the first child. Omit to manage Finch externally.
    - `:payment_retention_ms` — Executor terminal payment TTL (default: 86_400_000)
    - `:payment_cleanup_interval` — Executor cleanup interval (default: 3_600_000)
    - `:dedup_table` — Webhook dedup ETS table name (default: `FireBird.Webhook`)
    - `:rate_limit_table` — Webhook rate limit ETS table name (default: `FireBird.Webhook.RateLimit`)
    - `:dedup_ttl_ms` — Dedup entry TTL in ms (default: 86_400_000 = 24 h)
    - `:dedup_interval_ms` — Dedup cleanup interval in ms (default: 3_600_000 = 1 h)
  """

  use Supervisor

  @doc "Starts the FireBird supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl Supervisor
  def init(opts) do
    client = Keyword.fetch!(opts, :client)
    pubsub_name = Keyword.get(opts, :pubsub_name, FireBird.PubSub)

    finch_children =
      case Keyword.get(opts, :finch) do
        nil -> []
        finch_opts when is_list(finch_opts) -> [{Finch, finch_opts}]
      end

    children =
      finch_children ++
        [
          {FireBird.PubSub, name: pubsub_name},
          {FireBird.Monitor,
           [
             client: client,
             pubsub: pubsub_name,
             table_name: Keyword.get(opts, :liquidity_table, FireBird.Monitor),
             poll_interval: Keyword.get(opts, :poll_interval, 30_000),
             high_watermark: Keyword.get(opts, :high_watermark, 1_000_000),
             low_watermark: Keyword.get(opts, :low_watermark, 100_000),
             critical_watermark: Keyword.get(opts, :critical_watermark, 10_000)
           ]},
          {FireBird.Manager,
           [
             client: client,
             pubsub: pubsub_name,
             table_name: Keyword.get(opts, :invoice_table, FireBird.Manager),
             poll_interval: Keyword.get(opts, :invoice_poll_interval, 5_000),
             retention_ms: Keyword.get(opts, :invoice_retention_ms, 86_400_000),
             cleanup_interval: Keyword.get(opts, :invoice_cleanup_interval, 3_600_000)
           ]},
          {FireBird.Executor,
           [
             client: client,
             pubsub: pubsub_name,
             table_name: Keyword.get(opts, :payment_table, FireBird.Executor),
             max_concurrent: Keyword.get(opts, :max_concurrent, 10),
             wal: Keyword.get(opts, :wal),
             liquidity_table: Keyword.get(opts, :liquidity_table, FireBird.Monitor),
             retention_ms: Keyword.get(opts, :payment_retention_ms, 86_400_000),
             cleanup_interval: Keyword.get(opts, :payment_cleanup_interval, 3_600_000)
           ]},
          {FireBird.Cleaner,
           [
             dedup_table: Keyword.get(opts, :dedup_table, FireBird.Webhook),
             rate_limit_table: Keyword.get(opts, :rate_limit_table, FireBird.Webhook.RateLimit),
             ttl_ms: Keyword.get(opts, :dedup_ttl_ms, 86_400_000),
             interval_ms: Keyword.get(opts, :dedup_interval_ms, 3_600_000)
           ]}
        ]

    Supervisor.init(children,
      strategy: :rest_for_one,
      max_restarts: 10,
      max_seconds: 60
    )
  end
end
