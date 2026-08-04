defmodule FireBird.Bolt11 do
  @moduledoc """
  Pure BOLT11 invoice parser: amount extraction and payment-hash
  extraction (the `p` tagged field).

  Zero external dependencies — decodes the bech32 payload directly.
  Supports millibitcoin (m), microbitcoin (u), nanobitcoin (n), and
  picobitcoin (p) amount multipliers, and every network prefix in
  BOLT11 use today (`lnbc`, `lntb`, `lnbcrt`, `lntbs`).
  """

  @sats_per_btc 100_000_000

  # Multiplier denominators: amount * sats_per_btc / denominator = sats
  @multiplier_denominators %{
    ?m => 1_000,
    ?u => 1_000_000,
    ?n => 1_000_000_000,
    ?p => 1_000_000_000_000
  }

  # bech32 alphabet — index = 5-bit value
  @bech32_alphabet ~c"qpzry9x8gf2tvdw0s3jn54khce6mua7l"
  @bech32_lookup Map.new(Enum.with_index(@bech32_alphabet), fn {c, i} -> {c, i} end)

  # BOLT11 tagged-field values for the fields we consume. `p` = 1 =
  # payment_hash (256-bit binary, always exactly 52 bech32 chars =
  # 260 bits with 4 trailing padding bits).
  @tag_payment_hash 1
  @payment_hash_length_bech32 52

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

  @doc """
  Extracts the 32-byte payment hash (the `p` tagged field) from a
  BOLT11 invoice.

  Returns `{:ok, <<hash::binary-size(32)>>}` or `{:error, reason}`.

  This is the value the Lightning network keys payments by — the
  same one phoenixd's `/payments/outgoingbyhash/{paymentHash}` accepts
  — and is what upstream consumers should track outbound payments
  with rather than any locally-generated correlation id.
  """
  @spec payment_hash(String.t()) :: {:ok, binary()} | {:error, atom()}
  def payment_hash(bolt11) when is_binary(bolt11) do
    with {:ok, rest} <- strip_prefix(String.downcase(bolt11)),
         {:ok, payload_chars} <- data_chars(rest),
         {:ok, five_bit_stream} <- decode_bech32(payload_chars) do
      find_payment_hash(five_bit_stream)
    end
  end

  def payment_hash(_invalid), do: {:error, :invalid_input}

  # Strip the amount + multiplier + `1` separator, leaving just the
  # bech32 data payload (including the 6-char checksum tail).
  defp data_chars(rest) when is_binary(rest) do
    case String.split(rest, "1", parts: 2) do
      [_amount_prefix, payload] when byte_size(payload) > 6 ->
        # Trim the 6-char bech32 checksum — we don't verify it here;
        # payment_hash extraction is downstream of phoenixd's own
        # validation on invoice creation.
        chars = String.to_charlist(payload)
        {:ok, Enum.drop(chars, -6)}

      _other ->
        {:error, :malformed_payload}
    end
  end

  defp decode_bech32(chars) do
    reduced =
      Enum.reduce_while(chars, {:ok, []}, fn ch, {:ok, acc} ->
        case Map.fetch(@bech32_lookup, ch) do
          {:ok, value} -> {:cont, {:ok, [value | acc]}}
          :error -> {:halt, {:error, {:invalid_bech32_char, ch}}}
        end
      end)

    case reduced do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      err -> err
    end
  end

  # First 7 chars = 35-bit timestamp. Skip it, then walk tagged fields
  # looking for the payment_hash tag.
  defp find_payment_hash(stream) when length(stream) < 7,
    do: {:error, :payload_too_short}

  defp find_payment_hash(stream) do
    walk_tagged_fields(Enum.drop(stream, 7))
  end

  defp walk_tagged_fields([]), do: {:error, :payment_hash_missing}

  defp walk_tagged_fields([tag, len_hi, len_lo | rest]) do
    length_bech32 = len_hi * 32 + len_lo

    cond do
      length(rest) < length_bech32 ->
        {:error, :payload_truncated}

      tag == @tag_payment_hash and length_bech32 == @payment_hash_length_bech32 ->
        {:ok, five_bit_to_binary(Enum.take(rest, length_bech32), 256)}

      true ->
        walk_tagged_fields(Enum.drop(rest, length_bech32))
    end
  end

  defp walk_tagged_fields(_other), do: {:error, :payment_hash_missing}

  # Packs the 5-bit values MSB-first into a binary of exactly
  # `output_bits` bits, discarding any trailing padding bits the
  # bech32 encoding rounded up to. 52 chars × 5 bits = 260 bits;
  # payment_hash is 256 bits, so the final 4 bits are padding.
  defp five_bit_to_binary(chars, output_bits) do
    bitstream =
      Enum.reduce(chars, <<>>, fn value, acc -> <<acc::bitstring, value::size(5)>> end)

    <<hash::bitstring-size(output_bits), _padding::bitstring>> = bitstream
    <<hash::bitstring>>
  end
end
