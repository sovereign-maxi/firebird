defmodule FireBird.Executor do
  @moduledoc """
  Async payment execution with Task-based concurrency.

  Executes outbound Lightning payments asynchronously, tracking state in ETS.
  Supports configurable concurrency limits and optional WAL for crash safety.
  Terminal-state payments (succeeded/exhausted) are automatically cleaned up
  after `:retention_ms`.

  ## Options
    - `:client` — `{module, config}` tuple implementing `FireBird.Client`
    - `:pubsub` — PubSub registry name
    - `:table_name` — ETS table name (default: `FireBird.Executor`)
    - `:max_concurrent` — Maximum concurrent payment tasks (default: 10)
    - `:wal` — Optional `{module, config}` tuple implementing `FireBird.WAL`
    - `:liquidity_table` — Monitor ETS table for balance checks
    - `:retention_ms` — TTL for terminal payments in ms (default: 86_400_000 = 24 h)
    - `:cleanup_interval` — Cleanup check interval in ms (default: 3_600_000 = 1 h)
  """

  use GenServer

  alias FireBird.Events.{PaymentExhausted, PaymentFailed, PaymentSent, PaymentUnknown}
  alias FireBird.Payment
  alias FireBird.PubSub
  alias FireBird.Util

  require Logger

  defstruct [
    :client_mod,
    :client_config,
    :pubsub,
    :table_name,
    :max_concurrent,
    :wal,
    :liquidity_table,
    :retention_ms,
    :cleanup_interval,
    :cleanup_timer_ref,
    tasks: %{},
    retry_timers: %{}
  ]

  @default_max_concurrent 10
  @default_retention_ms 86_400_000
  @default_cleanup_interval 3_600_000

  # Non-terminal statuses in which a duplicate submit is rejected —
  # accepting one would spawn a second `pay_invoice` task for the
  # same invoice, and phoenixd's `/payinvoice` carries no idempotency
  # key, so the invoice could pay TWICE.
  @in_flight_statuses [:pending, :in_flight, :retrying]

  # Terminal statuses in which a duplicate submit is likewise
  # rejected: `:succeeded` because the invoice already paid,
  # `:unknown` because it MIGHT have paid and the caller must
  # reconcile before firing again.
  @locked_terminal_statuses [:succeeded, :unknown]

  @doc "Starts the payment executor."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Submits a payment for async execution."
  @spec submit(GenServer.server(), Payment.t(), timeout()) :: :ok | {:error, :at_capacity}
  def submit(server, %Payment{} = payment, timeout \\ 5_000) do
    GenServer.call(server, {:submit, payment}, timeout)
  end

  @doc "Looks up a payment by payment hash."
  @spec lookup(atom(), binary()) :: {:ok, Payment.t()} | {:error, :not_found}
  def lookup(table_name \\ __MODULE__, payment_hash) do
    case :ets.lookup(table_name, payment_hash) do
      [{^payment_hash, payment}] -> {:ok, payment}
      [] -> {:error, :not_found}
    end
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    {client_mod, client_config} = Keyword.fetch!(opts, :client)
    pubsub = Keyword.fetch!(opts, :pubsub)
    table_name = Keyword.get(opts, :table_name, __MODULE__)
    max_concurrent = Keyword.get(opts, :max_concurrent, @default_max_concurrent)
    Util.validate_positive!("FireBird.Executor", :max_concurrent, max_concurrent)

    wal =
      case Keyword.get(opts, :wal) do
        {mod, config} when is_atom(mod) -> {mod, config}
        nil -> nil
      end

    liquidity_table = Keyword.get(opts, :liquidity_table)
    retention_ms = Keyword.get(opts, :retention_ms, @default_retention_ms)
    cleanup_interval = Keyword.get(opts, :cleanup_interval, @default_cleanup_interval)

    if is_nil(wal) do
      Logger.warning(
        "Executor: started without WAL — " <>
          "in-flight payments will be lost on crash"
      )
    end

    :ets.new(table_name, [:named_table, :set, :public, read_concurrency: true])

    recovered_timers = recover_from_wal(wal, table_name, pubsub)

    state = %__MODULE__{
      client_mod: client_mod,
      client_config: client_config,
      pubsub: pubsub,
      table_name: table_name,
      max_concurrent: max_concurrent,
      wal: wal,
      liquidity_table: liquidity_table,
      retention_ms: retention_ms,
      cleanup_interval: cleanup_interval,
      retry_timers: recovered_timers
    }

    cleanup_timer_ref = schedule_cleanup(cleanup_interval)
    {:ok, %{state | cleanup_timer_ref: cleanup_timer_ref}}
  end

  @impl GenServer
  def handle_call({:submit, payment}, _from, state) do
    cond do
      map_size(state.tasks) >= state.max_concurrent ->
        {:reply, {:error, :at_capacity}, state}

      duplicate_reason = duplicate_submit_reason(state.table_name, payment.payment_hash) ->
        {:reply, {:error, {:duplicate, duplicate_reason}}, state}

      true ->
        case execute_payment(state, payment) do
          {:ok, state} -> {:reply, :ok, state}
          {:error, reason, state} -> {:reply, {:error, reason}, state}
        end
    end
  end

  # Refuses a repeat `submit` for a payment_hash the executor is
  # already tracking in a non-releasable state — this is the
  # per-invoice idempotency gate, distinct from the WAL's crash-
  # recovery replay path. Returns nil (fresh submit allowed) or the
  # atom describing the existing state.
  defp duplicate_submit_reason(table_name, payment_hash) do
    case :ets.lookup(table_name, payment_hash) do
      [{^payment_hash, %Payment{status: status}}]
      when status in @in_flight_statuses ->
        {:in_flight, status}

      [{^payment_hash, %Payment{status: status}}]
      when status in @locked_terminal_statuses ->
        {:already_terminal, status}

      _other ->
        nil
    end
  end

  @impl GenServer
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    if Map.has_key?(state.tasks, ref) do
      {payment_hash, tasks} = Map.pop(state.tasks, ref)
      state = %{state | tasks: tasks}
      state = handle_result(state, payment_hash, result)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    if Map.has_key?(state.tasks, ref) do
      {payment_hash, tasks} = Map.pop(state.tasks, ref)
      state = %{state | tasks: tasks}
      state = handle_result(state, payment_hash, {:error, {:task_crash, reason}})
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info({:retry, payment_hash}, state) do
    state = %{state | retry_timers: Map.delete(state.retry_timers, payment_hash)}

    case :ets.lookup(state.table_name, payment_hash) do
      [{^payment_hash, %Payment{} = payment}] when payment.status == :retrying ->
        case execute_payment(state, payment) do
          {:ok, state} ->
            {:noreply, state}

          {:error, _wal_reason, state} ->
            # Can't pay durably while the WAL is down — fail closed to
            # :unknown so the caller reconciles instead of the payment
            # wedging in :retrying with no timer left.
            {:noreply, handle_unknown_outcome(state, payment, "wal_unavailable_on_retry")}
        end

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(:cleanup, state) do
    deleted = cleanup_terminal(state)

    if deleted > 0 do
      :telemetry.execute(
        [:fire_bird, :payment, :cleanup],
        %{deleted: deleted},
        %{}
      )
    end

    cleanup_timer_ref = schedule_cleanup(state.cleanup_interval)
    {:noreply, %{state | cleanup_timer_ref: cleanup_timer_ref}}
  end

  def handle_info(msg, state) do
    Logger.debug("Executor: unexpected message #{inspect(msg)}")
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    if state.cleanup_timer_ref, do: Process.cancel_timer(state.cleanup_timer_ref)
    Enum.each(state.retry_timers, fn {_hash, ref} -> Process.cancel_timer(ref) end)

    case state.wal do
      {wal_mod, wal_config} ->
        state.table_name
        |> :ets.tab2list()
        |> Enum.each(fn {_hash, payment} ->
          # Persist anything still unresolved — :retrying included, since
          # its pending retry timer does not survive the restart.
          if payment.status in [:in_flight, :retrying] do
            wal_mod.append(wal_config, payment)
          end
        end)

      nil ->
        :ok
    end

    if :ets.whereis(state.table_name) != :undefined do
      :ets.delete(state.table_name)
    end

    :ok
  end

  defp recover_from_wal(nil, _table_name, _pubsub), do: %{}

  defp recover_from_wal({wal_mod, wal_config}, table_name, pubsub) do
    case wal_mod.recover(wal_config) do
      {:ok, payments} when is_list(payments) ->
        # Last record per payment_hash wins (recover/1 returns append
        # order, oldest first). Payments whose final record is terminal
        # (:succeeded / :exhausted / :failed) or already fail-closed
        # (:unknown) are resolved — only :in_flight / :retrying revive.
        revivable =
          payments
          |> Enum.filter(&match?(%Payment{}, &1))
          |> Enum.group_by(& &1.payment_hash)
          |> Enum.map(fn {_hash, records} -> List.last(records) end)
          |> Enum.filter(&(&1.status in [:in_flight, :retrying]))

        count = length(revivable)

        if count > 0 do
          Logger.warning(
            "Executor: recovering in-flight payments from WAL, " <>
              "marking each :unknown, caller must reconcile before releasing, count=#{count}"
          )
        end

        Enum.each(revivable, fn payment -> recover_single(payment, table_name, pubsub) end)

        # No retry timers: recovered payments are ambiguous by
        # definition (the VM crashed while the phoenixd task was in
        # flight) and must be reconciled against the node before any
        # further action, per the C1/C2 discipline.
        %{}

      {:error, reason} ->
        Logger.error("Executor: WAL recovery failed: #{inspect(reason)}")
        %{}
    end
  end

  # Restores a WAL-persisted payment as :unknown and publishes a
  # PaymentUnknown event so downstream consumers (mint quote layer)
  # transition to :settlement_unknown and hold reservations. Never
  # auto-retries — the previous auto-retry path bypassed the
  # submit-side dedup gate and could double-pay a payment that
  # phoenixd had already settled before the VM crashed.
  defp recover_single(%Payment{} = payment, table_name, pubsub) do
    reason = "wal_recovery: vm_crash_before_settlement"

    unknown = %{
      payment
      | status: :unknown,
        last_error: reason,
        completed_at: DateTime.utc_now()
    }

    :ets.insert(table_name, {payment.payment_hash, unknown})

    PubSub.publish(pubsub, :payment, %PaymentUnknown{
      payment_hash: payment.payment_hash,
      amount_sats: payment.amount_sats,
      reason: reason,
      attempt: payment.attempt,
      phoenixd_id: payment.phoenixd_id
    })

    :telemetry.execute(
      [:fire_bird, :payment, :recovered_unknown],
      %{count: 1},
      %{attempt: payment.attempt}
    )

    :ok
  end

  defp recover_single(_other, _table_name, _pubsub) do
    Logger.warning("Executor: skipping unrecognized WAL entry")
    :ok
  end

  defp execute_payment(state, payment) do
    case Payment.mark_in_flight(payment) do
      {:ok, in_flight} ->
        # The WAL record lands BEFORE the task starts — a hard crash
        # after this point is always recoverable. If the WAL is down,
        # refuse to pay: an undurably-dispatched payment is the
        # double-pay / lost-settlement path.
        case wal_append(state.wal, in_flight) do
          :ok ->
            :ets.insert(state.table_name, {payment.payment_hash, in_flight})

            task =
              Task.async(fn ->
                state.client_mod.pay_invoice(
                  state.client_config,
                  in_flight.bolt11,
                  in_flight.amount_sats,
                  in_flight.description || "",
                  in_flight.fee_limit_sats
                )
              end)

            :telemetry.execute(
              [:fire_bird, :payment, :submitted],
              %{count: 1},
              %{amount_sats: payment.amount_sats}
            )

            {:ok, %{state | tasks: Map.put(state.tasks, task.ref, payment.payment_hash)}}

          {:error, reason} ->
            Logger.error(
              "Executor: refusing to dispatch payment — WAL append failed: #{inspect(reason)}"
            )

            {:error, :wal_unavailable, state}
        end

      {:error, _reason} ->
        {:ok, state}
    end
  end

  # Crash-durability gate for dispatch. Returns :ok when no WAL is
  # configured (the init warning already covers that choice).
  defp wal_append(nil, _payment), do: :ok

  defp wal_append({wal_mod, wal_config}, payment) do
    case wal_mod.append(wal_config, payment) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Executor: WAL append failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Best-effort transition logging: the payment is already resolved on
  # Lightning by the time this runs, so a WAL failure cannot block the
  # bookkeeping — it only means a crash would recover this payment as
  # :unknown (fail-closed).
  defp wal_log(state, payment) do
    case wal_append(state.wal, payment) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp handle_result(state, payment_hash, result) do
    case :ets.lookup(state.table_name, payment_hash) do
      [{^payment_hash, payment}] ->
        process_result(state, payment, result)

      [] ->
        state
    end
  end

  defp process_result(state, payment, {:ok, resp}) when is_map(resp) do
    preimage_hex = resp["paymentPreimage"] || resp["preimage"]
    fee_raw = resp["routingFeeSat"] || resp["fees"]
    phoenixd_id = resp["paymentId"]

    if is_binary(preimage_hex) and preimage_hex != "" do
      process_preimage(state, payment, preimage_hex, fee_raw, phoenixd_id)
    else
      # A 2xx without a preimage is not proof of payment, and leaving
      # the payment :in_flight would wedge it forever — no task remains,
      # nothing re-polls, and the dedup gate blocks resubmission. The
      # payment may have settled; force reconciliation instead.
      Logger.warning(
        "Executor: success response missing preimage for " <>
          Base.encode16(payment.payment_hash, case: :lower) <>
          " — keys: #{inspect(Map.keys(resp))} — marking :unknown"
      )

      handle_unknown_outcome(state, payment, :missing_preimage_in_success_response)
    end
  end

  # 4xx errors get a node-side confirmation before classification:
  # "already paid" must never release, everything else may. 408/429
  # stay hard-:unknown — the node may still be processing.
  defp process_result(state, payment, {:error, {:http_error, status, _body} = reason})
       when status >= 400 and status < 500 and status not in [408, 429] do
    case confirm_4xx_outcome(state, payment) do
      :definitive -> handle_definitive_failure(state, payment, reason)
      :unknown -> handle_unknown_outcome(state, payment, reason)
    end
  end

  defp process_result(state, payment, {:error, reason}) do
    case classify_error(reason) do
      :retryable ->
        handle_retryable_error(state, payment, reason)

      :definitive ->
        handle_definitive_failure(state, payment, reason)

      :unknown ->
        handle_unknown_outcome(state, payment, reason)
    end
  end

  defp process_result(state, payment, {:ok, unexpected}) do
    # Same wedge risk as a missing preimage: nothing will drive this
    # payment forward again. Mark :unknown so the caller reconciles.
    Logger.warning(
      "Executor: unexpected success response for " <>
        Base.encode16(payment.payment_hash, case: :lower) <>
        " — #{inspect(unexpected)} — marking :unknown"
    )

    handle_unknown_outcome(state, payment, :unexpected_success_response)
  end

  # A 4xx from /payinvoice usually means the payment was never
  # attempted (bad invoice, unsupported network). But it can also
  # surface when the invoice was ALREADY settled — an out-of-band
  # payment, an operator remsh, or executor state loss followed by a
  # resubmit. The dedup gate cannot see those, and releasing a settled
  # payment's reservation is the double-spend path. Ask the node:
  # release only when it positively shows no settled payment exists.
  defp confirm_4xx_outcome(state, payment) do
    hash = payment.ln_payment_hash || payment.payment_hash

    case state.client_mod.get_outgoing_payment_by_hash(state.client_config, hash) do
      {:ok, %{"isPaid" => true}} ->
        Logger.error(
          "Executor: 4xx response but node shows payment SETTLED — " <>
            "marking :unknown for reconciliation"
        )

        :unknown

      {:ok, %{"completedAt" => completed_at}}
      when is_binary(completed_at) or is_integer(completed_at) ->
        # Terminal failure record on the node — provably not settled.
        :definitive

      {:ok, _still_pending} ->
        :unknown

      {:error, {:http_error, 404, _body}} ->
        # No outgoing record at all — the payment was never attempted.
        :definitive

      {:error, _lookup_failure} ->
        :unknown
    end
  end

  # Classifies an executor error into one of three buckets:
  #   * `:retryable`  — a bounded transient the caller may want us to
  #                     retry (structured phoenixd error naming
  #                     temporary route/liquidity condition).
  #   * `:definitive` — the payment definitively did NOT happen on
  #                     Lightning. Safe to release the reservation.
  #   * `:unknown`    — outcome undetermined (HTTP timeout, transport
  #                     error, 5xx, task crash). MUST reconcile with
  #                     the node before any release; never auto-retry.
  #
  # Conservative default: unknown. Any error whose semantics we can't
  # positively identify (retryable transient / definitive negative)
  # falls through to :unknown so the caller must reconcile before
  # releasing — a Finch timeout on a payment that later settles must
  # never trigger a release, because that's the double-spend path.
  @spec classify_error(term()) :: :retryable | :definitive | :unknown
  defp classify_error({:task_crash, _reason}), do: :unknown
  defp classify_error(%{__exception__: true, __struct__: Mint.TransportError}), do: :unknown
  defp classify_error({:http_error, status, _body}) when status >= 500, do: :unknown
  defp classify_error({:http_error, 408, _body}), do: :unknown
  defp classify_error({:http_error, 429, _body}), do: :unknown
  defp classify_error(:timeout), do: :unknown
  defp classify_error({:timeout, _reason}), do: :unknown

  # Circuit-breaker rejections happen before any bytes left the VM —
  # the node provably never saw the payment, so release is safe.
  defp classify_error(:circuit_open), do: :definitive
  defp classify_error(:breaker_unavailable), do: :definitive
  defp classify_error(%{__exception__: true, __struct__: Mint.TransportError}), do: :unknown
  defp classify_error({:http_error, status, _body}) when status >= 500, do: :unknown
  defp classify_error({:http_error, 408, _body}), do: :unknown
  defp classify_error({:http_error, 429, _body}), do: :unknown
  defp classify_error(:timeout), do: :unknown
  defp classify_error({:timeout, _reason}), do: :unknown

  defp classify_error({:phoenixd_error, kind, _msg})
       when kind in [:route_not_found, :insufficient_liquidity, :temporary_channel_failure] do
    :retryable
  end

  # 4xx responses never reach this function — process_result/3 routes
  # them through confirm_4xx_outcome/2 first, because a bare 4xx can
  # mean "already paid" and must never auto-release.

  defp classify_error(_other), do: :unknown

  defp handle_retryable_error(state, payment, reason) do
    reason_str = inspect(reason)

    case Payment.mark_failed(payment, reason_str) do
      {:ok, %Payment{status: :retrying} = retrying} ->
        wal_log(state, retrying)
        :ets.insert(state.table_name, {payment.payment_hash, retrying})

        PubSub.publish(state.pubsub, :payment, %PaymentFailed{
          payment_hash: payment.payment_hash,
          amount_sats: payment.amount_sats,
          reason: reason_str,
          attempt: retrying.attempt
        })

        :telemetry.execute(
          [:fire_bird, :payment, :failed],
          %{count: 1},
          %{attempt: retrying.attempt}
        )

        delay = Payment.next_retry_delay(retrying)
        timer_ref = Process.send_after(self(), {:retry, payment.payment_hash}, delay)
        %{state | retry_timers: Map.put(state.retry_timers, payment.payment_hash, timer_ref)}

      {:ok, %Payment{status: :exhausted} = exhausted} ->
        wal_log(state, exhausted)
        :ets.insert(state.table_name, {payment.payment_hash, exhausted})

        PubSub.publish(state.pubsub, :payment, %PaymentExhausted{
          payment_hash: payment.payment_hash,
          amount_sats: payment.amount_sats,
          reason: reason_str,
          attempts: exhausted.attempt
        })

        :telemetry.execute(
          [:fire_bird, :payment, :exhausted],
          %{count: 1},
          %{attempts: exhausted.attempt}
        )

        state

      {:error, _reason} ->
        state
    end
  end

  defp handle_definitive_failure(state, payment, reason) do
    reason_str = inspect(reason)

    case Payment.mark_definitively_failed(payment, reason_str) do
      {:ok, failed} ->
        wal_log(state, failed)
        :ets.insert(state.table_name, {payment.payment_hash, failed})

        # Publish as PaymentExhausted so downstream release-on-failed
        # consumers still trigger; :attempts reflects the actual
        # attempt count (definitive failures skip the retry ladder).
        PubSub.publish(state.pubsub, :payment, %PaymentExhausted{
          payment_hash: payment.payment_hash,
          amount_sats: payment.amount_sats,
          reason: reason_str,
          attempts: failed.attempt
        })

        :telemetry.execute(
          [:fire_bird, :payment, :definitively_failed],
          %{count: 1},
          %{attempt: failed.attempt}
        )

        state

      {:error, _reason} ->
        state
    end
  end

  defp handle_unknown_outcome(state, payment, reason) do
    reason_str = inspect(reason)

    case Payment.mark_unknown(payment, reason_str) do
      {:ok, unknown} ->
        wal_log(state, unknown)
        :ets.insert(state.table_name, {payment.payment_hash, unknown})

        PubSub.publish(state.pubsub, :payment, %PaymentUnknown{
          payment_hash: payment.payment_hash,
          amount_sats: payment.amount_sats,
          reason: reason_str,
          attempt: unknown.attempt,
          phoenixd_id: unknown.phoenixd_id
        })

        Logger.error(
          "Executor: payment outcome unknown, caller must reconcile before releasing, " <>
            "payment_hash=#{Base.encode16(payment.payment_hash, case: :lower)}, " <>
            "reason=#{reason_str}"
        )

        :telemetry.execute(
          [:fire_bird, :payment, :unknown],
          %{count: 1},
          %{attempt: unknown.attempt}
        )

        state

      {:error, _reason} ->
        state
    end
  end

  defp process_preimage(state, payment, preimage_hex, fee_raw, phoenixd_id) do
    case Base.decode16(preimage_hex, case: :mixed) do
      {:ok, preimage} ->
        fee_sats = coerce_integer(fee_raw)
        apply_preimage(state, payment, preimage, fee_sats, phoenixd_id)

      :error ->
        state
    end
  end

  defp apply_preimage(state, payment, preimage, fee_sats, phoenixd_id) do
    case Payment.mark_succeeded(payment, preimage, fee_sats, phoenixd_id) do
      {:ok, succeeded} ->
        wal_log(state, succeeded)
        :ets.insert(state.table_name, {payment.payment_hash, succeeded})

        PubSub.publish(state.pubsub, :payment, %PaymentSent{
          payment_hash: payment.payment_hash,
          amount_sats: payment.amount_sats,
          fee_sats: fee_sats,
          preimage: preimage
        })

        :telemetry.execute(
          [:fire_bird, :payment, :success],
          %{count: 1, fee_sats: fee_sats},
          %{amount_sats: payment.amount_sats}
        )

        state

      {:error, :invalid_preimage} ->
        # phoenixd returned a "success" whose preimage does not
        # hash to the invoice's payment hash. Not proof of payment.
        # Route through the unknown-outcome path so the caller
        # holds their reservation and reconciles with the node.
        handle_unknown_outcome(state, payment, :invalid_preimage)

      {:error, _reason} ->
        state
    end
  end

  defp cleanup_terminal(state) do
    now = DateTime.utc_now()

    succeeded = :ets.match_object(state.table_name, {:_, %{status: :succeeded}})
    exhausted = :ets.match_object(state.table_name, {:_, %{status: :exhausted}})
    failed = :ets.match_object(state.table_name, {:_, %{status: :failed}})

    # :unknown is deliberately never swept — it holds the dedup lock
    # until the caller reconciles with the node.
    Enum.reduce(succeeded ++ exhausted ++ failed, 0, fn {key, payment}, count ->
      if terminal_and_expired?(payment, now, state.retention_ms) do
        :ets.delete(state.table_name, key)
        count + 1
      else
        count
      end
    end)
  end

  defp terminal_and_expired?(
         %{status: status, completed_at: completed_at},
         now,
         retention_ms
       )
       when status in [:succeeded, :exhausted, :failed] and is_struct(completed_at, DateTime) do
    DateTime.diff(now, completed_at, :millisecond) > retention_ms
  end

  defp terminal_and_expired?(_payment, _now, _retention_ms), do: false

  defp coerce_integer(val) do
    case Util.parse_integer(val) do
      {:ok, int} ->
        int

      :error ->
        Logger.warning(
          "FireBird: unexpected value for integer conversion: #{inspect(val)}, defaulting to 0"
        )

        0
    end
  end

  defp schedule_cleanup(interval), do: Process.send_after(self(), :cleanup, interval)
end
