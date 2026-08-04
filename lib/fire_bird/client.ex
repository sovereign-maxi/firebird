defmodule FireBird.Client do
  @moduledoc """
  Behaviour contract for Phoenixd API operations.

  All callbacks take a `config` term as the first argument, allowing
  multiple client instances with different connection configurations.

  Implement this behaviour to provide a Phoenixd API adapter. The default
  implementation is `FireBird.HTTP`.
  """

  @type config :: term()
  @type payment_hash :: binary()
  @type bolt11 :: String.t()

  @doc """
  Creates a Lightning invoice and returns the raw API response. The
  4th argument is an optional invoice-expiry override in seconds
  forwarded as phoenixd's `expirySeconds`; `nil` uses phoenixd's
  default (currently one week). Callers with a shorter application-
  layer TTL (a mint quote, a checkout window) SHOULD pass a value
  ≤ that TTL so a late-paying user can't miss their claim window.
  """
  @callback create_invoice(config(), pos_integer(), String.t(), pos_integer() | nil) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Pays a BOLT11 invoice and returns the raw API response. The 5th
  argument is a flat routing-fee cap in sats forwarded as phoenixd's
  `maxFeeFlatSat`; `nil` disables the flat cap and falls back to
  phoenixd's own node policy (which is not user-visible from here).
  """
  @callback pay_invoice(
              config(),
              bolt11(),
              pos_integer(),
              String.t(),
              non_neg_integer() | nil
            ) :: {:ok, map()} | {:error, term()}

  @doc "Returns the current node balance in satoshis."
  @callback get_balance(config()) :: {:ok, map()} | {:error, term()}

  @doc "Fetches an incoming payment by its payment hash."
  @callback get_incoming_payment(config(), payment_hash()) :: {:ok, map()} | {:error, term()}

  @doc "Returns full node info including channel state and inbound liquidity."
  @callback get_info(config()) :: {:ok, map()} | {:error, term()}

  @doc "Checks if the Phoenixd node is reachable and healthy."
  @callback health_check(config()) :: :ok | {:error, term()}

  @doc "Fetches an outgoing payment by its phoenixd-assigned UUID."
  @callback get_outgoing_payment(config(), String.t()) :: {:ok, map()} | {:error, term()}

  @doc """
  Fetches an outgoing payment by the invoice's real Lightning payment
  hash (the 32-byte `p` tagged field of the bolt11). Preferred over
  `get_outgoing_payment/2` when reconciling after a crash, because
  the payment hash is derivable from the bolt11 the caller already
  holds even if the phoenixd-assigned UUID was lost.
  """
  @callback get_outgoing_payment_by_hash(config(), payment_hash()) ::
              {:ok, map()} | {:error, term()}

  @doc "Sends funds on-chain via splice-out. Returns the transaction ID."
  @callback send_onchain(config(), String.t(), pos_integer(), pos_integer()) ::
              {:ok, String.t()} | {:error, term()}

  @optional_callbacks [send_onchain: 4]
end
