defmodule FireBird.Manager do
  @moduledoc """
  Invoice lifecycle tracking via ETS.

  Manages the lifecycle of Lightning invoices — creating, polling for
  payment confirmation, and expiring stale invoices. Terminal-state
  invoices (paid/expired) are automatically cleaned up after `:retention_ms`.

  ## Options
    - `:client` — `{module, config}` tuple implementing `FireBird.Client`
    - `:pubsub` — PubSub registry name
    - `:table_name` — ETS table name (default: `FireBird.Manager`)
    - `:poll_interval` — Polling interval in ms (default: 5_000)
    - `:retention_ms` — TTL for terminal invoices in ms (default: 86_400_000 = 24 h)
    - `:cleanup_interval` — Cleanup check interval in ms (default: 3_600_000 = 1 h)
  """

  use GenServer

  alias FireBird.Events.{InvoiceExpired, InvoicePaid}
  alias FireBird.Invoice
  alias FireBird.PubSub
  alias FireBird.Util

  require Logger

  defstruct [
    :client_mod,
    :client_config,
    :pubsub,
    :table_name,
    :poll_interval,
    :timer_ref,
    :retention_ms,
    :cleanup_interval,
    :cleanup_timer_ref
  ]

  @default_poll_interval 5_000
  @default_retention_ms 86_400_000
  @default_cleanup_interval 3_600_000

  @doc "Starts the invoice manager."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Registers an invoice for lifecycle tracking."
  @spec track(GenServer.server(), Invoice.t(), timeout()) :: :ok
  def track(server, %Invoice{} = invoice, timeout \\ 5_000) do
    GenServer.call(server, {:track, invoice}, timeout)
  end

  @doc "Triggers an immediate payment check for a specific invoice (e.g. from webhook)."
  @spec check_payment(GenServer.server(), binary()) :: :ok
  def check_payment(server, payment_hash) when is_binary(payment_hash) do
    GenServer.cast(server, {:check_payment, payment_hash})
  end

  @doc "Looks up an invoice by payment hash."
  @spec lookup(atom(), binary()) :: {:ok, Invoice.t()} | {:error, :not_found}
  def lookup(table_name \\ __MODULE__, payment_hash) do
    case :ets.lookup(table_name, payment_hash) do
      [{^payment_hash, invoice}] -> {:ok, invoice}
      [] -> {:error, :not_found}
    end
  end

  @doc "Returns all tracked invoices."
  @spec list(atom()) :: [Invoice.t()]
  def list(table_name \\ __MODULE__) do
    table_name
    |> :ets.tab2list()
    |> Enum.map(fn {_key, invoice} -> invoice end)
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    {client_mod, client_config} = Keyword.fetch!(opts, :client)
    pubsub = Keyword.fetch!(opts, :pubsub)
    table_name = Keyword.get(opts, :table_name, __MODULE__)
    poll_interval = Keyword.get(opts, :poll_interval, @default_poll_interval)
    Util.validate_positive!("FireBird.Manager", :poll_interval, poll_interval)

    retention_ms = Keyword.get(opts, :retention_ms, @default_retention_ms)
    cleanup_interval = Keyword.get(opts, :cleanup_interval, @default_cleanup_interval)

    :ets.new(table_name, [:named_table, :set, :public, read_concurrency: true])

    state = %__MODULE__{
      client_mod: client_mod,
      client_config: client_config,
      pubsub: pubsub,
      table_name: table_name,
      poll_interval: poll_interval,
      retention_ms: retention_ms,
      cleanup_interval: cleanup_interval
    }

    timer_ref = schedule_poll(poll_interval)
    cleanup_timer_ref = schedule_cleanup(cleanup_interval)
    {:ok, %{state | timer_ref: timer_ref, cleanup_timer_ref: cleanup_timer_ref}}
  end

  @impl GenServer
  def handle_call({:track, invoice}, _from, state) do
    :ets.insert(state.table_name, {invoice.payment_hash, invoice})

    :telemetry.execute(
      [:fire_bird, :invoice, :tracked],
      %{count: 1},
      %{amount_sats: invoice.amount_sats}
    )

    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_cast({:check_payment, payment_hash}, state) do
    case :ets.lookup(state.table_name, payment_hash) do
      [{^payment_hash, %Invoice{status: :pending} = invoice}] ->
        poll_payment_status(state, invoice)

      _other ->
        :ok
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    check_pending_invoices(state)
    timer_ref = schedule_poll(state.poll_interval)
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  def handle_info(:cleanup, state) do
    deleted = cleanup_terminal(state)

    if deleted > 0 do
      :telemetry.execute(
        [:fire_bird, :invoice, :cleanup],
        %{deleted: deleted},
        %{}
      )
    end

    cleanup_timer_ref = schedule_cleanup(state.cleanup_interval)
    {:noreply, %{state | cleanup_timer_ref: cleanup_timer_ref}}
  end

  def handle_info(msg, state) do
    Logger.debug("Manager: unexpected message #{inspect(msg)}")
    {:noreply, state}
  end

  defp check_pending_invoices(state) do
    state.table_name
    |> :ets.match_object({:_, %{status: :pending}})
    |> Enum.each(fn {_hash, invoice} ->
      check_invoice(state, invoice)
    end)
  end

  defp check_invoice(state, invoice) do
    if Invoice.expired?(invoice) do
      expire_invoice(state, invoice)
    else
      poll_payment_status(state, invoice)
    end
  end

  defp poll_payment_status(state, invoice) do
    case state.client_mod.get_incoming_payment(state.client_config, invoice.payment_hash) do
      {:ok, %{"preimage" => preimage_hex} = resp}
      when is_binary(preimage_hex) and preimage_hex != "" ->
        validate_received_and_confirm(state, invoice, preimage_hex, resp)

      {:ok, _pending} ->
        :ok

      {:error, reason} ->
        Logger.debug(
          "Manager: poll for " <>
            "#{Base.encode16(invoice.payment_hash, case: :lower)} " <>
            "failed: #{inspect(reason)}"
        )
    end
  end

  defp validate_received_and_confirm(state, invoice, preimage_hex, resp) do
    case parse_received_sats(resp) do
      {:ok, received} when received >= invoice.amount_sats ->
        confirm_payment(state, invoice, preimage_hex, received)

      {:ok, received} ->
        Logger.warning(
          "Manager: underpaid invoice " <>
            "#{Base.encode16(invoice.payment_hash, case: :lower)} — " <>
            "received #{received} sats, expected #{invoice.amount_sats}"
        )

      :unknown ->
        # `receivedSat` absent from phoenixd response. Fail closed —
        # crediting the invoice at the expected amount without proof
        # that the expected amount landed is a free-mint vector under
        # any scenario where phoenixd is compromised, proxied, or its
        # API changes shape. If phoenixd genuinely stops emitting the
        # field on some future version, refuse to confirm and let the
        # operator investigate — do NOT auto-credit.
        Logger.error(
          "Manager: phoenixd response missing receivedSat for " <>
            "#{Base.encode16(invoice.payment_hash, case: :lower)} — " <>
            "refusing to confirm (fail-closed)"
        )
    end
  end

  defp parse_received_sats(%{"receivedSat" => val}) do
    case Util.parse_integer(val) do
      {:ok, n} -> {:ok, n}
      :error -> :unknown
    end
  end

  defp parse_received_sats(_resp), do: :unknown

  defp confirm_payment(state, invoice, preimage_hex, received_sats) do
    with {:ok, preimage} <- Base.decode16(preimage_hex, case: :mixed),
         :ok <- validate_preimage_length(preimage),
         {:ok, paid_invoice} <- Invoice.mark_paid(invoice, preimage) do
      :ets.insert(state.table_name, {invoice.payment_hash, paid_invoice})

      # Publish both `received_sats` (what actually landed on LN) and
      # `amount_sats` (what the invoice asked for). Consumers can
      # enforce `received >= expected` at the app boundary — a second
      # line of defense against a compromised phoenixd or a proxy that
      # silently downgrades the response.
      PubSub.publish(state.pubsub, :invoice, %InvoicePaid{
        payment_hash: invoice.payment_hash,
        amount_sats: invoice.amount_sats,
        received_sats: received_sats,
        paid_at: paid_invoice.paid_at
      })

      :telemetry.execute(
        [:fire_bird, :invoice, :settled],
        %{count: 1},
        %{amount_sats: invoice.amount_sats, received_sats: received_sats}
      )
    else
      error ->
        Logger.warning(
          "Manager: confirm failed for " <>
            "#{Base.encode16(invoice.payment_hash, case: :lower)}: #{inspect(error)}"
        )
    end
  end

  defp expire_invoice(state, invoice) do
    case Invoice.mark_expired(invoice) do
      {:ok, expired_invoice} ->
        :ets.insert(state.table_name, {invoice.payment_hash, expired_invoice})

        PubSub.publish(state.pubsub, :invoice, %InvoiceExpired{
          payment_hash: invoice.payment_hash,
          amount_sats: invoice.amount_sats,
          expired_at: DateTime.utc_now()
        })

        :telemetry.execute(
          [:fire_bird, :invoice, :expired],
          %{count: 1},
          %{amount_sats: invoice.amount_sats}
        )

      {:error, _reason} ->
        :ok
    end
  end

  defp cleanup_terminal(state) do
    now = DateTime.utc_now()

    paid = :ets.match_object(state.table_name, {:_, %{status: :paid}})
    expired = :ets.match_object(state.table_name, {:_, %{status: :expired}})

    Enum.reduce(paid ++ expired, 0, fn {key, invoice}, count ->
      if terminal_and_expired?(invoice, now, state.retention_ms) do
        :ets.delete(state.table_name, key)
        count + 1
      else
        count
      end
    end)
  end

  defp terminal_and_expired?(%{status: :paid, paid_at: paid_at}, now, retention_ms)
       when is_struct(paid_at, DateTime) do
    DateTime.diff(now, paid_at, :millisecond) > retention_ms
  end

  defp terminal_and_expired?(%{status: :expired, expires_at: expires_at}, now, retention_ms) do
    DateTime.diff(now, expires_at, :millisecond) > retention_ms
  end

  defp terminal_and_expired?(_invoice, _now, _retention_ms), do: false

  @impl GenServer
  def terminate(_reason, state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    if state.cleanup_timer_ref, do: Process.cancel_timer(state.cleanup_timer_ref)

    if :ets.whereis(state.table_name) != :undefined do
      :ets.delete(state.table_name)
    end

    :ok
  end

  defp validate_preimage_length(preimage) when byte_size(preimage) == 32, do: :ok

  defp validate_preimage_length(preimage),
    do: {:error, {:invalid_preimage_length, byte_size(preimage)}}

  defp schedule_poll(interval), do: Process.send_after(self(), :poll, interval)
  defp schedule_cleanup(interval), do: Process.send_after(self(), :cleanup, interval)
end
