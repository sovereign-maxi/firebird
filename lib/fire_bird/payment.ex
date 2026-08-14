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
  signals (structured phoenixd errors, or a 4xx that the executor has
  node-side CONFIRMED shows no settled payment — see `confirm_4xx_outcome`
  in `FireBird.Executor`).

  Tracks Lightning payments through their lifecycle with exponential
  backoff retry logic (max 3 attempts on `:retrying`; never on
  `:unknown`).
  """

  require Logger

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
    :fee_limit_sats,
    # The invoice's real 32-byte Lightning payment hash (`p` tagged
    # field). Distinct from `:payment_hash`, which callers currently
    # use as a local tracking key that may or may not match the real
    # LN hash. When set, `mark_succeeded/4` validates the preimage
    # against this value — the fail-closed proof-of-payment check.
    # When nil, the preimage is accepted unvalidated and a warning
    # is logged.
    :ln_payment_hash,
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
          fee_limit_sats: non_neg_integer() | nil,
          ln_payment_hash: binary() | nil,
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
    - `:fee_limit_sats` - Flat routing-fee cap in sats forwarded to
      phoenixd's `maxFeeFlatSat`; `nil` (default) means phoenixd's own
      node policy is the only bound. Callers holding a user-facing
      reserve MUST set this to that reserve — without it, the caller
      absorbs the difference silently on any route worse than the
      estimate.
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

  When `payment.ln_payment_hash` is set, the preimage MUST hash to
  it — the fail-closed proof-of-payment check that makes an outgoing
  success a genuine settlement rather than "phoenixd said so".
  When `ln_payment_hash` is nil, the caller hasn't provided the real
  hash to check against; the preimage is accepted unvalidated and
  a warning is logged.

  Returns `{:error, :not_in_flight}` if the payment is not in-flight,
  or `{:error, :invalid_preimage}` if validation fails.
  """
  @spec mark_succeeded(t(), binary(), non_neg_integer(), String.t() | nil) ::
          {:ok, t()} | {:error, :not_in_flight | :invalid_preimage}
  def mark_succeeded(payment, preimage, fee_sats, phoenixd_id \\ nil)

  def mark_succeeded(%__MODULE__{status: :in_flight} = payment, preimage, fee_sats, phoenixd_id)
      when is_binary(preimage) and is_integer(fee_sats) do
    case validate_preimage_against_hash(preimage, payment.ln_payment_hash) do
      :ok ->
        {:ok,
         %{
           payment
           | status: :succeeded,
             preimage: preimage,
             fee_sats: fee_sats,
             completed_at: DateTime.utc_now(),
             phoenixd_id: phoenixd_id || payment.phoenixd_id
         }}

      {:error, _reason} = err ->
        err
    end
  end

  def mark_succeeded(%__MODULE__{}, _preimage, _fee_sats, _phoenixd_id),
    do: {:error, :not_in_flight}

  defp validate_preimage_against_hash(_preimage, nil) do
    Logger.warning(
      "Payment: mark_succeeded called without ln_payment_hash — " <>
        "preimage accepted unvalidated (proof of payment NOT checked)"
    )

    :ok
  end

  defp validate_preimage_against_hash(preimage, expected_hash)
       when is_binary(expected_hash) and byte_size(expected_hash) == 32 do
    computed = :crypto.hash(:sha256, preimage)

    if :crypto.hash_equals(computed, expected_hash) do
      :ok
    else
      {:error, :invalid_preimage}
    end
  end

  defp validate_preimage_against_hash(_preimage, _malformed_hash),
    do: {:error, :invalid_preimage}

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
