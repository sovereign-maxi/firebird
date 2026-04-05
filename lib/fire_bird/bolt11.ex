defmodule FireBird.Bolt11 do
  @moduledoc """
  Pure BOLT11 invoice amount parser.

  Parses the amount portion of a BOLT11-encoded Lightning invoice string.
  Supports millibitcoin (m), microbitcoin (u), nanobitcoin (n), and
  picobitcoin (p) multipliers. Zero external dependencies.
  """

  @sats_per_btc 100_000_000

  # Multiplier denominators: amount * sats_per_btc / denominator = sats
  @multiplier_denominators %{
    ?m => 1_000,
    ?u => 1_000_000,
    ?n => 1_000_000_000,
    ?p => 1_000_000_000_000
  }

  @doc """
  Parses the amount in satoshis from a BOLT11 invoice string.

  Returns `{:ok, sats}` on success or `{:error, reason}` on failure.

  ## Examples

      iex> FireBird.Bolt11.parse_amount("lnbc1m1p...")
      {:ok, 100_000}

      iex> FireBird.Bolt11.parse_amount("lnbc100u1p...")
      {:ok, 10_000}

      iex> FireBird.Bolt11.parse_amount("lnbc1500n1p...")
      {:ok, 150}
  """
  @spec parse_amount(String.t()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def parse_amount(bolt11) when is_binary(bolt11) do
    bolt11
    |> String.downcase()
    |> strip_prefix()
    |> extract_amount_string()
    |> parse_amount_value()
  end

  def parse_amount(_invalid), do: {:error, :invalid_input}

  defp strip_prefix("lnbcrt" <> rest), do: {:ok, rest}
  defp strip_prefix("lntbs" <> rest), do: {:ok, rest}
  defp strip_prefix("lnbc" <> rest), do: {:ok, rest}
  defp strip_prefix("lntb" <> rest), do: {:ok, rest}
  defp strip_prefix(_other), do: {:error, :invalid_prefix}

  defp extract_amount_string({:error, _reason} = error), do: error

  defp extract_amount_string({:ok, rest}) do
    case Regex.run(~r/^(\d*)([munp]?)1/, rest) do
      [_full, digits, multiplier] -> {:ok, digits, multiplier}
      _no_match -> {:error, :invalid_amount}
    end
  end

  defp parse_amount_value({:error, _reason} = error), do: error

  defp parse_amount_value({:ok, "", ""}), do: {:ok, 0}

  defp parse_amount_value({:ok, digits, ""}) do
    case Integer.parse(digits) do
      {btc, ""} -> {:ok, btc * @sats_per_btc}
      _other -> {:error, :invalid_amount}
    end
  end

  defp parse_amount_value({:ok, digits, multiplier}) do
    case Integer.parse(digits) do
      {amount, ""} ->
        multiplier_char = multiplier |> String.to_charlist() |> hd()
        denominator = Map.fetch!(@multiplier_denominators, multiplier_char)
        sats = div(amount * @sats_per_btc, denominator)

        if sats == 0 and amount > 0 do
          {:error, :sub_satoshi}
        else
          {:ok, sats}
        end

      _other ->
        {:error, :invalid_amount}
    end
  end
end
