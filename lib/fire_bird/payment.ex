defmodule FireBird.Payment do
  @moduledoc """
  Outbound payment state machine: `:pending` → `:in_flight` → `:succeeded` | `:retrying` → `:exhausted`.

  Tracks Lightning payments through their lifecycle with exponential backoff
  retry logic (max 3 attempts).
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
    attempt: 0,
    max_attempts: 3
  ]

  @type status :: :pending | :in_flight | :succeeded | :retrying | :exhausted

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
  Marks an in-flight payment as succeeded with preimage and fee.

  Returns `{:error, :not_in_flight}` if the payment is not in-flight.
  """
  @spec mark_succeeded(t(), binary(), non_neg_integer()) ::
          {:ok, t()} | {:error, :not_in_flight}
  def mark_succeeded(%__MODULE__{status: :in_flight} = payment, preimage, fee_sats)
      when is_binary(preimage) and is_integer(fee_sats) do
    {:ok,
     %{
       payment
       | status: :succeeded,
         preimage: preimage,
         fee_sats: fee_sats,
         completed_at: DateTime.utc_now()
     }}
  end

  def mark_succeeded(%__MODULE__{}, _preimage, _fee_sats), do: {:error, :not_in_flight}

  @doc """
  Marks an in-flight payment as failed. Transitions to `:retrying` if attempts
  remain, or `:exhausted` if max attempts reached.

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
