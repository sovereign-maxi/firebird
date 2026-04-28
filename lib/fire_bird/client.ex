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

  @doc "Creates a Lightning invoice and returns the raw API response."
  @callback create_invoice(config(), pos_integer(), String.t()) ::
              {:ok, map()} | {:error, term()}

  @doc "Pays a BOLT11 invoice and returns the raw API response."
  @callback pay_invoice(config(), bolt11(), pos_integer(), String.t()) ::
              {:ok, map()} | {:error, term()}

  @doc "Returns the current node balance in satoshis."
  @callback get_balance(config()) :: {:ok, map()} | {:error, term()}

  @doc "Fetches an incoming payment by its payment hash."
  @callback get_incoming_payment(config(), payment_hash()) :: {:ok, map()} | {:error, term()}

  @doc "Returns full node info including channel state and inbound liquidity."
  @callback get_info(config()) :: {:ok, map()} | {:error, term()}

  @doc "Checks if the Phoenixd node is reachable and healthy."
  @callback health_check(config()) :: :ok | {:error, term()}

  @doc "Fetches an outgoing payment by its UUID."
  @callback get_outgoing_payment(config(), String.t()) :: {:ok, map()} | {:error, term()}

  @doc "Sends funds on-chain via splice-out. Returns the transaction ID."
  @callback send_onchain(config(), String.t(), pos_integer(), pos_integer()) ::
              {:ok, String.t()} | {:error, term()}

  @optional_callbacks [send_onchain: 4]
end
