defmodule FireBird.Webhook do
  @moduledoc """
  Plug router for Phoenixd webhook callbacks.

  Handles incoming webhook notifications from Phoenixd with HMAC-SHA256
  verification, replay protection, event deduplication, and rate limiting.

  ## Configuration via `init/1` opts
    - `:webhook_secret` — HMAC-SHA256 shared secret (required)
    - `:invoice_manager` — Manager server name/pid (required)
    - `:dedup_table` — ETS table name for deduplication (default: `FireBird.Webhook`)
    - `:rate_limit_table` — ETS table for rate limiting (default: `FireBird.Webhook.RateLimit`)
    - `:rate_limit_max` — Max requests per window per IP (default: 100)
    - `:rate_limit_window_ms` — Rate limit window in ms (default: 60_000)

  ## Usage

      # In your Phoenix/Plug router:
      forward "/webhooks/lightning", FireBird.Webhook,
        webhook_secret: "secret",
        invoice_manager: FireBird.Manager,
        dedup_table: FireBird.Webhook
  """

  use Plug.Router

  require Logger

  plug(:match)
  plug(:dispatch)

  @impl Plug
  def init(opts) do
    dedup_table = Keyword.get(opts, :dedup_table, __MODULE__)
    ensure_ets_table(dedup_table)

    rate_limit_table = Keyword.get(opts, :rate_limit_table, FireBird.Webhook.RateLimit)
    ensure_ets_table(rate_limit_table)

    webhook_secret = Keyword.fetch!(opts, :webhook_secret)
    validate_webhook_secret!(webhook_secret)

    %{
      webhook_secret: webhook_secret,
      invoice_manager: Keyword.fetch!(opts, :invoice_manager),
      dedup_table: dedup_table,
      rate_limit_table: rate_limit_table,
      rate_limit_max: Keyword.get(opts, :rate_limit_max, 100),
      rate_limit_window_ms: Keyword.get(opts, :rate_limit_window_ms, 60_000)
    }
  end

  @impl Plug
  def call(conn, opts) do
    conn
    |> Plug.Conn.put_private(:fire_bird_opts, opts)
    |> super(opts)
  end

  post "/payment-received" do
    opts = conn.private[:fire_bird_opts]

    with {:ok, body, conn} <- Plug.Conn.read_body(conn, length: 10_000),
         :ok <- verify_signature(body, conn, opts.webhook_secret),
         :ok <- rate_limit(conn),
         {:ok, payload} <- Jason.decode(body) do
      # Handle BEFORE recording the dedup marker: handling is an
      # idempotent re-poll trigger, so a crash between the two loses
      # nothing — the redelivery simply re-triggers the poll. The old
      # order (dedup first) could swallow a delivery until the slow
      # poll sweep noticed.
      handle_payment_received(payload, opts)
      status = record_dedup(payload, opts.dedup_table)
      :telemetry.execute([:fire_bird, :webhook, :received], %{count: 1}, %{status: status})

      if status == :duplicate,
        do: send_resp(conn, 200, "already processed"),
        else: send_resp(conn, 200, "ok")
    else
      {:error, :invalid_signature} ->
        :telemetry.execute([:fire_bird, :webhook, :received], %{count: 1}, %{status: :invalid_sig})
        send_resp(conn, 401, "invalid signature")

      {:error, :rate_limited} ->
        send_resp(conn, 429, "rate limit exceeded")

      {:more, _partial, _conn} ->
        :telemetry.execute([:fire_bird, :webhook, :received], %{count: 1}, %{status: :too_large})
        send_resp(conn, 400, "bad request")

      {:error, reason} ->
        Logger.warning("Webhook: error: #{inspect(reason)}")
        :telemetry.execute([:fire_bird, :webhook, :received], %{count: 1}, %{status: :error})
        send_resp(conn, 400, "bad request")
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # Runs AFTER HMAC verification, inside the route: behind Tor every
  # request arrives from 127.0.0.1, so the per-IP bucket is effectively
  # global. Bad-signature junk must not burn the bucket and 429
  # legitimate phoenixd callbacks.
  defp rate_limit(conn) do
    opts = conn.private[:fire_bird_opts]
    table = opts.rate_limit_table
    max = opts.rate_limit_max
    window_ms = opts.rate_limit_window_ms
    key = conn.remote_ip |> :inet.ntoa() |> to_string()
    now = System.monotonic_time(:millisecond)

    # Atomically increment count, inserting {key, 0, now} as default if missing
    new_count = :ets.update_counter(table, key, {2, 1}, {key, 0, now})

    # Check if the window has expired
    case :ets.lookup(table, key) do
      [{^key, _count, window_start}] when now - window_start >= window_ms ->
        # Window expired — reset (small race on reset is acceptable: ≤1 extra request)
        :ets.insert(table, {key, 1, now})
        :ok

      _active_window ->
        if new_count > max do
          :telemetry.execute([:fire_bird, :webhook, :rate_limited], %{count: 1}, %{})
          {:error, :rate_limited}
        else
          :ok
        end
    end
  rescue
    ArgumentError ->
      Logger.warning("Webhook: rate limit table missing, recreating")
      ensure_ets_table(conn.private[:fire_bird_opts].rate_limit_table)
      :ok
  end

  defp verify_signature(body, conn, secret) do
    case Plug.Conn.get_req_header(conn, "x-phoenix-signature") do
      [signature] ->
        expected = Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)

        if Plug.Crypto.secure_compare(signature, expected) do
          :ok
        else
          {:error, :invalid_signature}
        end

      _no_header ->
        {:error, :invalid_signature}
    end
  end

  defp record_dedup(%{"paymentHash" => hash}, table) when is_binary(hash) do
    if :ets.insert_new(table, {hash, System.monotonic_time(:millisecond)}),
      do: :ok,
      else: :duplicate
  rescue
    ArgumentError ->
      Logger.warning("Webhook: dedup table missing, recreating")
      ensure_ets_table(table)
      :ok
  end

  defp record_dedup(_payload, _table), do: :ok

  defp handle_payment_received(%{"paymentHash" => hash_hex} = _payload, opts) do
    case Base.decode16(hash_hex, case: :mixed) do
      {:ok, payment_hash} ->
        FireBird.Manager.check_payment(opts.invoice_manager, payment_hash)

      :error ->
        Logger.warning("Webhook: invalid paymentHash hex: #{hash_hex}")
    end

    :ok
  end

  defp handle_payment_received(_payload, _opts), do: :ok

  defp validate_webhook_secret!(secret)
       when is_binary(secret) and byte_size(secret) > 0,
       do: :ok

  defp validate_webhook_secret!(secret) do
    raise ArgumentError,
          "Webhook: webhook_secret must be a non-empty binary, got: #{inspect(secret)}"
  end

  defp ensure_ets_table(table_name) do
    :ets.new(table_name, [:named_table, :set, :public, read_concurrency: true])
  rescue
    ArgumentError -> :ok
  end
end
