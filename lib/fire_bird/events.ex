defmodule FireBird.Events do
  @moduledoc """
  Event structs for the FireBird Lightning integration.

  All events include a `version: 1` field for forward compatibility.

  ## Topics

  - `:invoice` — `InvoicePaid`, `InvoiceExpired`
  - `:payment` — `PaymentSent`, `PaymentFailed`, `PaymentExhausted`
  - `:liquidity` — `LiquidityLow`, `LiquidityCritical`, `LiquidityRecovered`
  """

  defmodule InvoicePaid do
    @moduledoc "Emitted when an invoice is confirmed paid with a valid preimage."

    @enforce_keys [:payment_hash, :amount_sats, :paid_at]
    defstruct [:payment_hash, :amount_sats, :paid_at, version: 1]

    @type t :: %__MODULE__{
            payment_hash: binary(),
            amount_sats: pos_integer(),
            paid_at: DateTime.t(),
            version: pos_integer()
          }
  end

  defmodule InvoiceExpired do
    @moduledoc "Emitted when a pending invoice passes its expiration time."

    @enforce_keys [:payment_hash, :amount_sats, :expired_at]
    defstruct [:payment_hash, :amount_sats, :expired_at, version: 1]

    @type t :: %__MODULE__{
            payment_hash: binary(),
            amount_sats: pos_integer(),
            expired_at: DateTime.t(),
            version: pos_integer()
          }
  end

  defmodule PaymentSent do
    @moduledoc "Emitted when an outbound payment succeeds."

    @enforce_keys [:payment_hash, :amount_sats, :fee_sats, :preimage]
    defstruct [:payment_hash, :amount_sats, :fee_sats, :preimage, version: 1]

    @type t :: %__MODULE__{
            payment_hash: binary(),
            amount_sats: pos_integer(),
            fee_sats: non_neg_integer(),
            preimage: binary(),
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
    defstruct [:payment_hash, :amount_sats, :reason, :attempt, version: 1]

    @type t :: %__MODULE__{
            payment_hash: binary(),
            amount_sats: pos_integer(),
            reason: String.t(),
            attempt: pos_integer(),
            version: pos_integer()
          }
  end

  defmodule PaymentExhausted do
    @moduledoc "Emitted when a payment exhausts all retry attempts."

    @enforce_keys [:payment_hash, :amount_sats, :reason, :attempts]
    defstruct [:payment_hash, :amount_sats, :reason, :attempts, version: 1]

    @type t :: %__MODULE__{
            payment_hash: binary(),
            amount_sats: pos_integer(),
            reason: String.t(),
            attempts: pos_integer(),
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
