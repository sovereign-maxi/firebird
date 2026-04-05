defmodule FireBird.Fees do
  @moduledoc """
  Fee calculation with parts-per-million (PPM), floor, and ceiling clamping.

  All functions accept a config keyword list instead of reading application env.
  Config keys: `:fee_ppm` (default 1000), `:fee_min_sats` (default 1),
  `:fee_max_sats` (default 100_000).
  """

  @default_fee_ppm 1_000
  @default_fee_min_sats 1
  @default_fee_max_sats 100_000

  @doc """
  Calculates the deposit fee for a given amount in satoshis.

  ## Options
    - `:fee_ppm` — Fee in parts per million (default: 1000, i.e. 0.1%)
    - `:fee_min_sats` — Minimum fee floor (default: 1)
    - `:fee_max_sats` — Maximum fee ceiling (default: 100_000)
  """
  @spec deposit_fee(pos_integer(), keyword()) :: non_neg_integer()
  def deposit_fee(amount_sats, opts \\ []) do
    calculate(amount_sats, opts)
  end

  @doc """
  Calculates the withdrawal fee for a given amount in satoshis.

  Uses the same PPM/clamp logic as `deposit_fee/2`.
  """
  @spec withdrawal_fee(pos_integer(), keyword()) :: non_neg_integer()
  def withdrawal_fee(amount_sats, opts \\ []) do
    calculate(amount_sats, opts)
  end

  @doc """
  Core fee calculation: PPM with ceiling division, clamped to [min, max].

  ## Examples

      iex> FireBird.Fees.calculate(1_000_000, fee_ppm: 1000)
      1000

      iex> FireBird.Fees.calculate(100, fee_ppm: 1000, fee_min_sats: 1)
      1
  """
  @spec calculate(pos_integer(), keyword()) :: non_neg_integer()
  def calculate(amount_sats, opts \\ []) when is_integer(amount_sats) and amount_sats > 0 do
    ppm = Keyword.get(opts, :fee_ppm, @default_fee_ppm)
    min_fee = Keyword.get(opts, :fee_min_sats, @default_fee_min_sats)
    max_fee = Keyword.get(opts, :fee_max_sats, @default_fee_max_sats)

    amount_sats
    |> ppm_ceil(ppm)
    |> max(min_fee)
    |> min(max_fee)
  end

  defp ppm_ceil(amount, ppm) do
    div(amount * ppm + 999_999, 1_000_000)
  end
end
