defmodule FireBird.Events do
  @moduledoc """
  Event structs for the FireBird Lightning integration.

  All events include a `version: 1` field for forward compatibility.

  ## Topics

  - `:invoice` — `InvoicePaid`, `InvoiceExpired`
  - `:payment` — `PaymentSent`, `PaymentFailed`, `PaymentExhausted`, `PaymentUnknown`
  - `:liquidity` — `LiquidityLow`, `LiquidityCritical`, `LiquidityRecovered`
  """

  defmodule InvoicePaid do
    @moduledoc """
    Emitted when an invoice is confirmed paid with a valid preimage.

    `amount_sats` is the value the invoice was minted for (i.e. what
    the mint expected). `received_sats` is what phoenixd reported as
    actually landed on the Lightning side. Consumers should assert
    `received_sats >= amount_sats` at the app boundary — a second
    line of defense against a compromised phoenixd or downgraded
    proxy layer.
    """

    @enforce_keys [:payment_hash, :amount_sats, :received_sats, :paid_at]
    defstruct [:payment_hash, :amount_sats, :received_sats, :paid_at, :external_id, version: 1]

    @type t :: %__MODULE__{
            payment_hash: binary(),
            amount_sats: pos_integer(),
            received_sats: pos_integer(),
            paid_at: DateTime.t(),
            external_id: String.t() | nil,
            version: pos_integer()
          }
  end

  defmodule InvoiceExpired do
    @moduledoc "Emitted when a pending invoice passes its expiration time."

    @enforce_keys [:payment_hash, :amount_sats, :expired_at]
    defstruct [:payment_hash, :amount_sats, :expired_at, :external_id, version: 1]

    @type t :: %__MODULE__{
            payment_hash: binary(),
            amount_sats: pos_integer(),
            expired_at: DateTime.t(),
            external_id: String.t() | nil,
            version: pos_integer()
          }
  end

  defmodule PaymentSent do
    @moduledoc "Emitted when an outbound payment succeeds."

    @enforce_keys [:payment_hash, :amount_sats, :fee_sats, :preimage]
    defstruct [
      :payment_hash,
      :amount_sats,
      :fee_sats,
      :preimage,
      :external_id,
      :generation,
      :description,
      version: 1
    ]

    @type t :: %__MODULE__{
            payment_hash: binary(),
            amount_sats: pos_integer(),
            fee_sats: non_neg_integer(),
            preimage: binary(),
            external_id: String.t() | nil,
            generation: String.t() | nil,
            description: String.t() | nil,
            version: pos_integer()
          }

    defimpl Inspect do
      @moduledoc false

      @spec inspect(FireBird.Events.PaymentSent.t(), Inspect.Opts.t()) :: term()
      def inspect(%FireBird.Events.PaymentSent{} = event, opts) do
        redacted = %{event | preimage: if(event.preimage, do: "**REDACTED**")}
        Inspect.Any.inspect(redacted, opts)
      end
    end
  end

  defmodule PaymentFailed do
    @moduledoc "Emitted when a payment attempt fails but may be retried."

    @enforce_keys [:payment_hash, :amount_sats, :reason, :attempt]
    defstruct [
      :payment_hash,
      :amount_sats,
      :reason,
      :attempt,
      :external_id,
      :generation,
      version: 1
    ]

    @type t :: %__MODULE__{
            payment_hash: binary(),
            amount_sats: pos_integer(),
            reason: String.t(),
            attempt: pos_integer(),
            external_id: String.t() | nil,
            generation: String.t() | nil,
            version: pos_integer()
          }
  end

  defmodule PaymentExhausted do
    @moduledoc "Emitted when a payment exhausts all retry attempts."

    @enforce_keys [:payment_hash, :amount_sats, :reason, :attempts]
    defstruct [
      :payment_hash,
      :amount_sats,
      :reason,
      :attempts,
      :external_id,
      :generation,
      version: 1
    ]

    @type t :: %__MODULE__{
            payment_hash: binary(),
            amount_sats: pos_integer(),
            reason: String.t(),
            attempts: pos_integer(),
            external_id: String.t() | nil,
            generation: String.t() | nil,
            version: pos_integer()
          }
  end

  defmodule PaymentUnknown do
    @moduledoc """
    Emitted when a payment's Lightning outcome is undetermined.
    Consumers MUST retain reservations and reconcile the immutable
    `external_id` / `generation` attempt, not whichever payment hash
    happens to be current.
    """

    @enforce_keys [:payment_hash, :amount_sats, :reason, :attempt]
    defstruct [
      :payment_hash,
      :amount_sats,
      :reason,
      :attempt,
      :phoenixd_id,
      :external_id,
      :generation,
      version: 1
    ]

    @type t :: %__MODULE__{
            payment_hash: binary(),
            amount_sats: pos_integer(),
            reason: String.t(),
            attempt: pos_integer(),
            phoenixd_id: String.t() | nil,
            external_id: String.t() | nil,
            generation: String.t() | nil,
            version: pos_integer()
          }
  end

  defmodule LiquidityLow do
    @moduledoc "Emitted when balance drops below the low watermark."

    @enforce_keys [:balance_sats, :threshold_sats]
    defstruct [:balance_sats, :threshold_sats, version: 1]

    @type t :: %__MODULE__{
            balance_sats: non_neg_integer(),
            threshold_sats: non_neg_integer(),
            version: pos_integer()
          }
  end

  defmodule LiquidityCritical do
    @moduledoc "Emitted when balance drops below the critical threshold (zero or near-zero)."

    @enforce_keys [:balance_sats, :threshold_sats]
    defstruct [:balance_sats, :threshold_sats, version: 1]

    @type t :: %__MODULE__{
            balance_sats: non_neg_integer(),
            threshold_sats: non_neg_integer(),
            version: pos_integer()
          }
  end

  defmodule LiquidityRecovered do
    @moduledoc "Emitted when balance recovers above the high watermark after being low."

    @enforce_keys [:balance_sats, :threshold_sats]
    defstruct [:balance_sats, :threshold_sats, version: 1]

    @type t :: %__MODULE__{
            balance_sats: non_neg_integer(),
            threshold_sats: non_neg_integer(),
            version: pos_integer()
          }
  end
end
