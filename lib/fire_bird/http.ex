defmodule FireBird.HTTP do
  @moduledoc """
  Phoenixd REST client implementing the `FireBird.Client` behaviour.

  Uses Finch for HTTP requests with Basic auth. All operations take a
  `%FireBird.HTTP{}` config struct as the first argument.

  ## Usage

      config = FireBird.HTTP.new(
        base_url: "http://localhost:9740",
        password: "mypassword",
        finch_name: MyApp.Finch
      )

      FireBird.HTTP.create_invoice(config, 1000, "test invoice")
  """

  @behaviour FireBird.Client

  require Logger

  @enforce_keys [:base_url, :password, :finch_name]
  defstruct [:base_url, :password, :finch_name, receive_timeout: 30_000]

  @type t :: %__MODULE__{
          base_url: String.t(),
          password: String.t(),
          finch_name: atom(),
          receive_timeout: pos_integer()
        }

  @doc """
  Creates a new HTTP client config.

  ## Required options
    - `:base_url` — Phoenixd base URL (e.g. "http://localhost:9740")
    - `:password` — HTTP Basic auth password
    - `:finch_name` — Registered Finch pool name
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    base_url = Keyword.fetch!(opts, :base_url)
    validate_url!(base_url)

    struct!(__MODULE__, opts)
  end

  @impl FireBird.Client
  def create_invoice(%__MODULE__{} = config, amount_sats, description)
      when is_integer(amount_sats) and amount_sats > 0 do
    body =
      URI.encode_query(%{
        "amountSat" => amount_sats,
        "description" => sanitize_description(description)
      })

    post(config, "/createinvoice", body)
  end

  @impl FireBird.Client
  def pay_invoice(%__MODULE__{} = config, bolt11, amount_sats, description, fee_limit_sats)
      when is_binary(bolt11) and is_integer(amount_sats) and amount_sats > 0 and
             (is_nil(fee_limit_sats) or (is_integer(fee_limit_sats) and fee_limit_sats >= 0)) do
    base_params = %{
      "invoice" => bolt11,
      "amountSat" => amount_sats,
      "description" => sanitize_description(description)
    }

    post(config, "/payinvoice", URI.encode_query(maybe_put_fee_cap(base_params, fee_limit_sats)))
  end

  # phoenixd's `maxFeeFlatSat` is optional; omit the key entirely when
  # the caller passes nil so we don't accidentally cap at 0 (which
  # phoenixd rejects any nonzero-routed payment against).
  defp maybe_put_fee_cap(params, nil), do: params

  defp maybe_put_fee_cap(params, sats) when is_integer(sats) and sats >= 0,
    do: Map.put(params, "maxFeeFlatSat", sats)

  @impl FireBird.Client
  def get_balance(%__MODULE__{} = config) do
    get(config, "/getbalance")
  end

  @impl FireBird.Client
  def get_incoming_payment(%__MODULE__{} = config, payment_hash) when is_binary(payment_hash) do
    hex_hash = Base.encode16(payment_hash, case: :lower)
    get(config, "/payments/incoming/#{hex_hash}")
  end

  @impl FireBird.Client
  def get_outgoing_payment(%__MODULE__{} = config, payment_id) when is_binary(payment_id) do
    get(config, "/payments/outgoing/#{payment_id}")
  end

  @impl FireBird.Client
  def get_outgoing_payment_by_hash(%__MODULE__{} = config, payment_hash)
      when is_binary(payment_hash) do
    hex_hash = Base.encode16(payment_hash, case: :lower)
    get(config, "/payments/outgoingbyhash/#{hex_hash}")
  end

  @impl FireBird.Client
  def get_info(%__MODULE__{} = config) do
    get(config, "/getinfo")
  end

  @impl FireBird.Client
  def health_check(%__MODULE__{} = config) do
    case get_info(config) do
      {:ok, _info} -> :ok
      error -> error
    end
  end

  @doc """
  Sends funds to a Bitcoin address via splice-out.

  Returns `{:ok, txid}` where txid is the on-chain transaction ID string.
  The channel remains open after the splice.
  """
  @impl FireBird.Client
  @spec send_onchain(t(), String.t(), pos_integer(), pos_integer()) ::
          {:ok, String.t()} | {:error, term()}
  def send_onchain(%__MODULE__{} = config, address, amount_sats, feerate_sat_byte)
      when is_binary(address) and is_integer(amount_sats) and amount_sats > 0 and
             is_integer(feerate_sat_byte) and feerate_sat_byte > 0 do
    body =
      URI.encode_query(%{
        "amountSat" => amount_sats,
        "address" => address,
        "feerateSatByte" => feerate_sat_byte
      })

    case post(config, "/sendtoaddress", body) do
      {:ok, txid} when is_binary(txid) -> {:ok, txid}
      {:ok, %{"txid" => txid}} -> {:ok, txid}
      {:ok, other} -> {:ok, to_string(other)}
      error -> error
    end
  end

  defp post(%__MODULE__{} = config, path, body) do
    url = config.base_url <> path

    Finch.build(:post, url, headers(config), body)
    |> Finch.request(config.finch_name, receive_timeout: config.receive_timeout)
    |> handle_response()
  end

  defp get(%__MODULE__{} = config, path) do
    url = config.base_url <> path

    Finch.build(:get, url, headers(config))
    |> Finch.request(config.finch_name, receive_timeout: config.receive_timeout)
    |> handle_response()
  end

  defp headers(%__MODULE__{password: password}) do
    encoded = Base.encode64(":" <> password)

    [
      {"authorization", "Basic " <> encoded},
      {"content-type", "application/x-www-form-urlencoded"}
    ]
  end

  defp handle_response({:ok, %Finch.Response{status: status, body: body}})
       when status in 200..299 do
    case Jason.decode(body) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, {:decode_error, reason}}
    end
  end

  defp handle_response({:ok, %Finch.Response{status: status, body: body}}) do
    {:error, {:http_error, status, body}}
  end

  defp handle_response({:error, _reason} = error), do: error

  defp validate_url!(url) do
    uri = URI.parse(url)

    unless uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
      raise ArgumentError, "invalid base_url: #{inspect(url)} (must be http:// or https://)"
    end

    if uri.scheme == "http" do
      Logger.warning(
        "HTTP: base_url uses plaintext HTTP (#{url}). " <>
          "Credentials will be sent unencrypted. Use https:// in production."
      )
    end
  end

  defimpl Inspect do
    @moduledoc false

    @spec inspect(FireBird.HTTP.t(), Inspect.Opts.t()) :: term()
    def inspect(%FireBird.HTTP{} = config, opts) do
      redacted = %{config | password: "**REDACTED**"}
      Inspect.Any.inspect(redacted, opts)
    end
  end

  defp sanitize_description(description) when is_binary(description) do
    description
    |> String.slice(0, 639)
    |> String.replace(~r/[^\w\s\-.,!?@#$%&*()\[\]{}:;'"\/\\+=<>~`]/u, "")
  end
end
