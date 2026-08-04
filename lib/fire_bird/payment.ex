defmodule FireBird.Payment do
  @moduledoc """
  Outbound payment state machine:

      :pending → :in_flight ──┬── :succeeded
                              ├── :retrying → :in_flight (loop, N attempts) → :exhausted
                              ├── :failed    (definitive negative — safe to release)
                              └── :unknown   (ambiguous outcome — MUST reconcile)

  `:unknown` is the fail-closed state: transport errors, HTTP timeouts,
  task crashes, and 5xx responses arrive here because the outcome on
  Lightning is genuinely undetermined — the mint MUST NOT release the
  caller's reservation until it has reconciled with the node. `:failed`
  is reserved for explicit "payment definitively did not happen"
  signals (structured phoenixd errors, 4xx responses that name a
  reason).

  Tracks Lightning payments through their lifecycle with exponential
  backoff retry logic (max 3 attempts on `:retrying`; never on
  `:unknown`).
  """

  @enforce_keys [:payment_hash, :bolt11, :amount_sats, :status, :created_at]
  defstruct [
    :payment_hash,
    :bolt11,
    :amount_sats,
    :status,
    :created_at,
    :preimage,
    :fee_sats,
    :completed_at,
    :description,
    :external_id,
    :last_error,
    # Phoenixd's own paymentId (UUID) captured from the /payinvoice
    # response so recovery + resolver can reconcile via
    # `/payments/outgoing/{paymentId}` when we have it. Nil when we
    # never got a response back (transport error, task crash).
    :phoenixd_id,
    attempt: 0,
    max_attempts: 3
  ]

  @type status ::
          :pending
          | :in_flight
          | :succeeded
          | :retrying
          | :exhausted
          | :failed
          | :unknown

  @type t :: %__MODULE__{
          payment_hash: binary(),
          bolt11: String.t(),
          amount_sats: pos_integer(),
          status: status(),
          created_at: DateTime.t(),
          preimage: binary() | nil,
          fee_sats: non_neg_integer() | nil,
          completed_at: DateTime.t() | nil,
          description: String.t() | nil,
          external_id: String.t() | nil,
          last_error: String.t() | nil,
          phoenixd_id: String.t() | nil,
          attempt: non_neg_integer(),
          max_attempts: pos_integer()
        }

  @base_delay_ms 1_000
  @max_delay_ms 30_000

  @doc """
  Creates a new pending payment.

  ## Required fields
    - `:payment_hash` - 32-byte hash
    - `:bolt11` - BOLT11 encoded invoice string
    - `:amount_sats` - Amount in satoshis
    - `:created_at` - Creation timestamp

  ## Optional fields
    - `:description` - Human-readable description
    - `:external_id` - Caller-provided correlation ID
    - `:max_attempts` - Maximum retry attempts (default: 3)
  """
  @spec new(keyword()) :: t()
  def new(attrs) do
    struct!(
      __MODULE__,
      attrs
      |> Keyword.put(:status, :pending)
      |> Keyword.put_new(:attempt, 0)
      |> Keyword.put_new(:max_attempts, 3)
    )
  end

  @doc """
  Marks a pending or retrying payment as in-flight, incrementing the attempt counter.

  Returns `{:error, :not_sendable}` if the payment is not in a sendable state.
  """
  @spec mark_in_flight(t()) :: {:ok, t()} | {:error, :not_sendable}
  def mark_in_flight(%__MODULE__{status: status} = payment)
      when status in [:pending, :retrying] do
    {:ok, %{payment | status: :in_flight, attempt: payment.attempt + 1}}
  end

  def mark_in_flight(%__MODULE__{}), do: {:error, :not_sendable}

  @doc """
  Marks an in-flight payment as succeeded with preimage, fee, and
  (when present) phoenixd's own paymentId for downstream reconciliation.

  Returns `{:error, :not_in_flight}` if the payment is not in-flight.
  """
  @spec mark_succeeded(t(), binary(), non_neg_integer(), String.t() | nil) ::
          {:ok, t()} | {:error, :not_in_flight}
  def mark_succeeded(payment, preimage, fee_sats, phoenixd_id \\ nil)

  def mark_succeeded(%__MODULE__{status: :in_flight} = payment, preimage, fee_sats, phoenixd_id)
      when is_binary(preimage) and is_integer(fee_sats) do
    {:ok,
     %{
       payment
       | status: :succeeded,
         preimage: preimage,
         fee_sats: fee_sats,
         completed_at: DateTime.utc_now(),
         phoenixd_id: phoenixd_id || payment.phoenixd_id
     }}
  end

  def mark_succeeded(%__MODULE__{}, _preimage, _fee_sats, _phoenixd_id),
    do: {:error, :not_in_flight}

  @doc """
  Marks an in-flight payment as failed AFTER a retryable-error attempt.
  Transitions to `:retrying` if attempts remain, or `:exhausted` if
  max attempts reached. Both status values are eligible for release
  (the payment was fully classified as "did not settle on Lightning").

  Reserved for errors the caller can classify as retryable (e.g. a
  known-retryable phoenixd error) — ambiguous / transport / timeout
  cases must go through `mark_unknown/2` instead.

  Returns `{:error, :not_in_flight}` if the payment is not in-flight.
  """
  @spec mark_failed(t(), String.t()) :: {:ok, t()} | {:error, :not_in_flight}
  def mark_failed(%__MODULE__{status: :in_flight} = payment, reason) when is_binary(reason) do
    new_status = if payment.attempt >= payment.max_attempts, do: :exhausted, else: :retrying

    base = %{payment | status: new_status, last_error: reason}

    result =
      if new_status == :exhausted do
        %{base | completed_at: DateTime.utc_now()}
      else
        base
      end

    {:ok, result}
  end

  def mark_failed(%__MODULE__{}, _reason), do: {:error, :not_in_flight}

  @doc """
  Marks an in-flight payment as definitively failed (single terminal
  transition — no retry) after an unambiguous negative signal from
  the node (structured error, 4xx with a reason phrase). Callers may
  safely release any reservation held against this payment.

  Returns `{:error, :not_in_flight}` if the payment is not in-flight.
  """
  @spec mark_definitively_failed(t(), String.t()) ::
          {:ok, t()} | {:error, :not_in_flight}
  def mark_definitively_failed(%__MODULE__{status: :in_flight} = payment, reason)
      when is_binary(reason) do
    {:ok,
     %{
       payment
       | status: :failed,
         last_error: reason,
         completed_at: DateTime.utc_now()
     }}
  end

  def mark_definitively_failed(%__MODULE__{}, _reason), do: {:error, :not_in_flight}

  @doc """
  Marks an in-flight payment as `:unknown`. Terminal from the
  executor's perspective — no auto-retry — but the caller MUST
  reconcile with the node before releasing any reservation, because
  the payment may still be in flight on Lightning.

  Returns `{:error, :not_in_flight}` if the payment is not in-flight.
  """
  @spec mark_unknown(t(), String.t()) :: {:ok, t()} | {:error, :not_in_flight}
  def mark_unknown(%__MODULE__{status: :in_flight} = payment, reason) when is_binary(reason) do
    {:ok,
     %{
       payment
       | status: :unknown,
         last_error: reason,
         completed_at: DateTime.utc_now()
     }}
  end

  def mark_unknown(%__MODULE__{}, _reason), do: {:error, :not_in_flight}

  @doc """
  Calculates the next retry delay in milliseconds using exponential backoff.

  Formula: `min(base_delay * 2^(attempt - 1), max_delay)`
  """
  @spec next_retry_delay(t()) :: non_neg_integer()
  def next_retry_delay(%__MODULE__{attempt: attempt}) do
    delay = @base_delay_ms * Integer.pow(2, max(attempt - 1, 0))
    min(delay, @max_delay_ms)
  end

  @doc "Returns true if the payment can be retried (status is `:retrying`)."
  @spec retriable?(t()) :: boolean()
  def retriable?(%__MODULE__{status: :retrying}), do: true
  def retriable?(%__MODULE__{}), do: false
end
