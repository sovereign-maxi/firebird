defmodule FireBird.Invoice do
  @moduledoc """
  Invoice state machine: `:pending` → `:paid` | `:expired`.

  Tracks Lightning invoices through their lifecycle. Preimage is validated
  against payment_hash via SHA-256 on payment confirmation.
  """

  @enforce_keys [:payment_hash, :bolt11, :amount_sats, :status, :created_at, :expires_at]
  defstruct [
    :payment_hash,
    :bolt11,
    :amount_sats,
    :status,
    :created_at,
    :expires_at,
    :preimage,
    :paid_at,
    :description,
    :external_id
  ]

  @type status :: :pending | :paid | :expired

  @type t :: %__MODULE__{
          payment_hash: binary(),
          bolt11: String.t(),
          amount_sats: pos_integer(),
          status: status(),
          created_at: DateTime.t(),
          expires_at: DateTime.t(),
          preimage: binary() | nil,
          paid_at: DateTime.t() | nil,
          description: String.t() | nil,
          external_id: String.t() | nil
        }

  @doc """
  Creates a new pending invoice.

  ## Required fields
    - `:payment_hash` - 32-byte hash
    - `:bolt11` - BOLT11 encoded invoice string
    - `:amount_sats` - Amount in satoshis
    - `:created_at` - Creation timestamp
    - `:expires_at` - Expiration timestamp

  ## Optional fields
    - `:description` - Human-readable description
    - `:external_id` - Caller-provided correlation ID
  """
  @spec new(keyword()) :: t()
  def new(attrs) do
    struct!(
      __MODULE__,
      attrs
      |> Keyword.put(:status, :pending)
      |> Keyword.put_new(:preimage, nil)
      |> Keyword.put_new(:paid_at, nil)
    )
  end

  @doc """
  Marks a pending invoice as paid with preimage validation.

  The preimage must SHA-256 hash to the invoice's payment_hash.
  Returns `{:error, :invalid_preimage}` if validation fails,
  or `{:error, :not_pending}` if the invoice is not in pending status.
  """
  @spec mark_paid(t(), binary()) :: {:ok, t()} | {:error, :invalid_preimage | :not_pending}
  def mark_paid(%__MODULE__{status: :pending} = invoice, preimage) when is_binary(preimage) do
    computed = :crypto.hash(:sha256, preimage)

    if Plug.Crypto.secure_compare(computed, invoice.payment_hash) do
      {:ok, %{invoice | status: :paid, preimage: preimage, paid_at: DateTime.utc_now()}}
    else
      {:error, :invalid_preimage}
    end
  end

  def mark_paid(%__MODULE__{}, _preimage), do: {:error, :not_pending}

  @doc """
  Marks a pending invoice as expired.

  Returns `{:error, :not_pending}` if the invoice is not in pending status.
  """
  @spec mark_expired(t()) :: {:ok, t()} | {:error, :not_pending}
  def mark_expired(%__MODULE__{status: :pending} = invoice) do
    {:ok, %{invoice | status: :expired}}
  end

  def mark_expired(%__MODULE__{}), do: {:error, :not_pending}

  @doc "Returns true if the invoice has passed its expiration time."
  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) != :lt
  end

  defimpl Inspect do
    @moduledoc false

    @spec inspect(FireBird.Invoice.t(), Inspect.Opts.t()) :: term()
    def inspect(%FireBird.Invoice{} = invoice, opts) do
      redacted = %{invoice | preimage: if(invoice.preimage, do: "**REDACTED**")}

      Inspect.Any.inspect(redacted, opts)
    end
  end
end
