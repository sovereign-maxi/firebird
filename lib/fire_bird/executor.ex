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

  alias FireBird.Events.{PaymentExhausted, PaymentFailed, PaymentSent}
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

    recovered_timers = recover_from_wal(wal, table_name)

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
    if map_size(state.tasks) >= state.max_concurrent do
      {:reply, {:error, :at_capacity}, state}
    else
      state = execute_payment(state, payment)
      {:reply, :ok, state}
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
        state = execute_payment(state, payment)
        {:noreply, state}

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
          if payment.status == :in_flight do
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

  defp recover_from_wal(nil, _table_name), do: %{}

  defp recover_from_wal({wal_mod, wal_config}, table_name) do
    case wal_mod.recover(wal_config) do
      {:ok, payments} when is_list(payments) ->
        count = length(payments)

        if count > 0 do
          Logger.info("Executor: recovering #{count} payments from WAL")
        end

        payments
        |> Enum.with_index()
        |> Enum.reduce(%{}, fn {payment, index}, timers ->
          case recover_single(payment, table_name, index) do
            {:ok, hash, timer_ref} -> Map.put(timers, hash, timer_ref)
            :skip -> timers
          end
        end)

      {:error, reason} ->
        Logger.error("Executor: WAL recovery failed: #{inspect(reason)}")
        %{}
    end
  end

  defp recover_single(%Payment{} = payment, table_name, index) do
    if payment.attempt >= payment.max_attempts do
      exhausted = %{payment | status: :exhausted, completed_at: DateTime.utc_now()}
      :ets.insert(table_name, {payment.payment_hash, exhausted})
      :skip
    else
      retrying = %{payment | status: :retrying}
      :ets.insert(table_name, {payment.payment_hash, retrying})
      delay = 500 + index * 200
      timer_ref = Process.send_after(self(), {:retry, payment.payment_hash}, delay)
      {:ok, payment.payment_hash, timer_ref}
    end
  end

  defp recover_single(_other, _table_name, _index) do
    Logger.warning("Executor: skipping unrecognized WAL entry")
    :skip
  end

  defp execute_payment(state, payment) do
    case Payment.mark_in_flight(payment) do
      {:ok, in_flight} ->
        :ets.insert(state.table_name, {payment.payment_hash, in_flight})

        task =
          Task.async(fn ->
            state.client_mod.pay_invoice(
              state.client_config,
              in_flight.bolt11,
              in_flight.amount_sats,
              in_flight.description || ""
            )
          end)

        :telemetry.execute(
          [:fire_bird, :payment, :submitted],
          %{count: 1},
          %{amount_sats: payment.amount_sats}
        )

        %{state | tasks: Map.put(state.tasks, task.ref, payment.payment_hash)}

      {:error, _reason} ->
        state
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

    if is_binary(preimage_hex) and preimage_hex != "" do
      process_preimage(state, payment, preimage_hex, fee_raw)
    else
      Logger.warning(
        "Executor: success response missing preimage for " <>
          Base.encode16(payment.payment_hash, case: :lower) <>
          " — keys: #{inspect(Map.keys(resp))}"
      )

      state
    end
  end

  defp process_result(state, payment, {:error, reason}) do
    reason_str = inspect(reason)

    case Payment.mark_failed(payment, reason_str) do
      {:ok, %Payment{status: :retrying} = retrying} ->
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

  defp process_result(state, payment, {:ok, unexpected}) do
    Logger.warning(
      "Executor: unexpected success response for " <>
        Base.encode16(payment.payment_hash, case: :lower) <>
        " — #{inspect(unexpected)}"
    )

    state
  end

  defp process_preimage(state, payment, preimage_hex, fee_raw) do
    with {:ok, preimage} <- Base.decode16(preimage_hex, case: :mixed) do
      fee_sats = coerce_integer(fee_raw)

      case Payment.mark_succeeded(payment, preimage, fee_sats) do
        {:ok, succeeded} ->
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

        {:error, _reason} ->
          :ok
      end
    end

    state
  end

  defp cleanup_terminal(state) do
    now = DateTime.utc_now()

    succeeded = :ets.match_object(state.table_name, {:_, %{status: :succeeded}})
    exhausted = :ets.match_object(state.table_name, {:_, %{status: :exhausted}})

    Enum.reduce(succeeded ++ exhausted, 0, fn {key, payment}, count ->
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
       when status in [:succeeded, :exhausted] and is_struct(completed_at, DateTime) do
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
