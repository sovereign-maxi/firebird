defmodule FireBird.Bolt11 do
  @moduledoc """
  BOLT11 amount/tag extraction and strict invoice validation.

  The extraction helpers are intentionally small and retain their legacy
  behaviour. Money-moving callers use `validate/2`, which additionally
  checks the Bech32 checksum, tagged-field structure, recoverable
  secp256k1 signature, network, and expiry.
  """

  import Bitwise

  @type validated_invoice :: %{
          amount_sats: non_neg_integer(),
          payment_hash: binary(),
          description: String.t() | nil,
          description_hash: binary() | nil,
          network: :mainnet | :testnet | :signet | :regtest,
          timestamp: non_neg_integer(),
          expiry_seconds: pos_integer(),
          expires_at: DateTime.t(),
          min_final_cltv_expiry: non_neg_integer(),
          payee: binary() | nil,
          features: bitstring() | nil
        }

  @sats_per_btc 100_000_000
  @default_expiry_seconds 3_600
  @max_invoice_bytes 8_192

  @multiplier_denominators %{
    ?m => 1_000,
    ?u => 1_000_000,
    ?n => 1_000_000_000,
    ?p => 1_000_000_000_000
  }

  @bech32_alphabet ~c"qpzry9x8gf2tvdw0s3jn54khce6mua7l"
  @bech32_lookup Map.new(Enum.with_index(@bech32_alphabet), fn {c, i} -> {c, i} end)
  @bech32_generators [0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3]

  @tag_payment_hash 1
  @tag_description_hash 23
  @tag_description 13
  @tag_expiry 6
  @tag_min_final_cltv_expiry 24
  @tag_payee 19
  @tag_features 5
  @payment_hash_length_bech32 52
  @signature_length_bech32 104
  @single_tags [1, 5, 6, 13, 16, 19, 23, 24]

  @secp256k1_p 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
  @secp256k1_n 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
  @secp256k1_gx 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
  @secp256k1_gy 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8

  @doc "Parses the whole-satoshi amount from a BOLT11 invoice."
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
        numerator = amount * @sats_per_btc

        cond do
          numerator == 0 -> {:ok, 0}
          rem(numerator, denominator) != 0 -> {:error, :sub_satoshi}
          true -> {:ok, div(numerator, denominator)}
        end

      _other ->
        {:error, :invalid_amount}
    end
  end

  @doc "Extracts the 32-byte payment hash without validating the invoice."
  @spec payment_hash(String.t()) :: {:ok, binary()} | {:error, atom()}
  def payment_hash(bolt11) when is_binary(bolt11) do
    with {:ok, rest} <- strip_prefix(String.downcase(bolt11)),
         {:ok, payload_chars} <- data_chars(rest),
         {:ok, five_bit_stream} <- decode_bech32(payload_chars) do
      find_payment_hash(five_bit_stream)
    end
  end

  def payment_hash(_invalid), do: {:error, :invalid_input}

  @doc "Extracts the 32-byte description hash without validating the invoice."
  @spec description_hash(String.t()) :: {:ok, binary()} | {:error, atom()}
  def description_hash(bolt11) when is_binary(bolt11) do
    with {:ok, rest} <- strip_prefix(String.downcase(bolt11)),
         {:ok, payload_chars} <- data_chars(rest),
         {:ok, five_bit_stream} <- decode_bech32(payload_chars) do
      find_description_hash(five_bit_stream)
    end
  end

  def description_hash(_invalid), do: {:error, :invalid_input}

  @doc """
  Fully validates a BOLT11 invoice for an expected network and time.

  Options:
    * `:network` — `:mainnet` (default), `:testnet`, `:signet`, or `:regtest`.
    * `:now` — `DateTime` used for expiry checks (defaults to `DateTime.utc_now/0`).
    * `:safety_window_seconds` — required time remaining (default 30 seconds).
  """
  @spec validate(String.t(), keyword()) :: {:ok, validated_invoice()} | {:error, atom() | tuple()}
  def validate(bolt11, opts \\ [])

  def validate(bolt11, opts) when is_binary(bolt11) and is_list(opts) do
    network = Keyword.get(opts, :network, :mainnet)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    safety_window = Keyword.get(opts, :safety_window_seconds, 30)

    with :ok <- validate_prefix(bolt11),
         :ok <- validate_invoice_bytes(bolt11),
         {:ok, normalized} <- normalize_invoice(bolt11),
         {:ok, hrp, encoded_data} <- split_invoice(normalized),
         {:ok, expected_network, rest} <- parse_hrp(hrp),
         :ok <- validate_network(expected_network, network),
         {:ok, amount_sats} <- parse_hrp_amount(rest),
         {:ok, words} <- decode_bech32(String.to_charlist(encoded_data)),
         :ok <- verify_checksum(hrp, words),
         {:ok, signed_words, signature_words} <- split_signature(words),
         {:ok, timestamp, tags} <- decode_tags(signed_words),
         {:ok, invoice} <- build_invoice(timestamp, tags, amount_sats, expected_network),
         :ok <- verify_signature(hrp, signed_words, signature_words, invoice.payee),
         :ok <- validate_expiry(invoice, now, safety_window) do
      {:ok, invoice}
    end
  end

  def validate(_bolt11, _opts), do: {:error, :invalid_input}

  defp validate_prefix(invoice) do
    normalized = String.downcase(invoice)

    if String.starts_with?(normalized, ["lnbcrt", "lntbs", "lnbc", "lntb"]),
      do: :ok,
      else: {:error, :invalid_prefix}
  end

  defp validate_invoice_bytes(invoice) do
    cond do
      byte_size(invoice) > @max_invoice_bytes -> {:error, :invoice_too_long}
      byte_size(invoice) < 20 -> {:error, :malformed_payload}
      not String.printable?(invoice) -> {:error, :invalid_bech32}
      true -> :ok
    end
  end

  defp normalize_invoice(invoice) do
    cond do
      invoice != String.downcase(invoice) and invoice != String.upcase(invoice) ->
        {:error, :mixed_case}

      String.contains?(invoice, [" ", "\t", "\r", "\n"]) ->
        {:error, :invalid_bech32}

      true ->
        {:ok, String.downcase(invoice)}
    end
  end

  defp split_invoice(invoice) do
    case :binary.matches(invoice, "1") do
      [] ->
        {:error, :malformed_payload}

      matches ->
        {separator, 1} = List.last(matches)
        hrp = binary_part(invoice, 0, separator)
        data = binary_part(invoice, separator + 1, byte_size(invoice) - separator - 1)

        if byte_size(hrp) > 0 and byte_size(data) > 6 + @signature_length_bech32,
          do: {:ok, hrp, data},
          else: {:error, :malformed_payload}
    end
  end

  defp parse_hrp("lnbcrt" <> rest), do: {:ok, :regtest, rest}
  defp parse_hrp("lntbs" <> rest), do: {:ok, :signet, rest}
  defp parse_hrp("lnbc" <> rest), do: {:ok, :mainnet, rest}
  defp parse_hrp("lntb" <> rest), do: {:ok, :testnet, rest}
  defp parse_hrp(_other), do: {:error, :invalid_prefix}

  defp parse_hrp_amount(rest) do
    case Regex.run(~r/^(\d*)([munp]?)$/, rest) do
      [_full, digits, multiplier] -> parse_amount_value({:ok, digits, multiplier})
      _other -> {:error, :invalid_amount}
    end
  end

  defp validate_network(network, network), do: :ok
  defp validate_network(_actual, _expected), do: {:error, :wrong_network}

  defp verify_checksum(hrp, words) do
    values = expand_hrp(hrp) ++ words

    if bech32_polymod(values) == 1, do: :ok, else: {:error, :invalid_checksum}
  end

  defp expand_hrp(hrp) do
    chars = String.to_charlist(hrp)
    Enum.map(chars, &(&1 >>> 5)) ++ [0] ++ Enum.map(chars, &Bitwise.band(&1, 31))
  end

  defp bech32_polymod(values) do
    checksum =
      Enum.reduce(values, 1, fn value, checksum ->
        top = checksum >>> 25
        shifted = Bitwise.bxor(Bitwise.band(checksum, 0x1FFFFFF) <<< 5, value)

        @bech32_generators
        |> Enum.with_index()
        |> Enum.reduce(shifted, fn {generator, index}, acc ->
          if Bitwise.band(top >>> index, 1) == 1, do: Bitwise.bxor(acc, generator), else: acc
        end)
      end)

    checksum
  end

  defp split_signature(words) when length(words) < 6 + @signature_length_bech32 + 7,
    do: {:error, :payload_too_short}

  defp split_signature(words) do
    data = Enum.drop(words, -6)
    {signed, signature} = Enum.split(data, length(data) - @signature_length_bech32)

    if length(signature) == @signature_length_bech32,
      do: {:ok, signed, signature},
      else: {:error, :invalid_signature_structure}
  end

  defp decode_tags([_first_word | _remaining_words] = words) when length(words) >= 7 do
    {timestamp_words, tag_words} = Enum.split(words, 7)
    timestamp = Enum.reduce(timestamp_words, 0, &((&2 <<< 5) + &1))

    case walk_tags(tag_words, []) do
      {:ok, tags} -> {:ok, timestamp, tags}
      error -> error
    end
  end

  defp decode_tags(_other), do: {:error, :payload_too_short}

  defp walk_tags([], tags), do: {:ok, Enum.reverse(tags)}

  defp walk_tags([tag, len_hi, len_lo | rest], tags) do
    length_words = len_hi * 32 + len_lo

    cond do
      length(rest) < length_words ->
        {:error, :payload_truncated}

      tag in @single_tags and Enum.any?(tags, fn {existing, _value} -> existing == tag end) ->
        {:error, {:duplicate_tag, tag}}

      rem(tag, 2) == 0 and tag not in [6, 16, 18, 24] ->
        {:error, {:unknown_required_tag, tag}}

      true ->
        {value, remaining} = Enum.split(rest, length_words)
        walk_tags(remaining, [{tag, value} | tags])
    end
  end

  defp walk_tags(_other, _tags), do: {:error, :payload_truncated}

  defp build_invoice(timestamp, tags, amount_sats, network) do
    with {:ok, payment_hash} <- required_hash(tags, @tag_payment_hash, :payment_hash_missing),
         :ok <- validate_payment_secret(tags),
         {:ok, description, description_hash} <- description_fields(tags),
         {:ok, expiry_seconds} <- optional_integer(tags, @tag_expiry, @default_expiry_seconds),
         {:ok, min_final_cltv_expiry} <- optional_integer(tags, @tag_min_final_cltv_expiry, 18),
         {:ok, payee} <- optional_payee(tags),
         {:ok, features} <- optional_binary(tags, @tag_features),
         true <- expiry_seconds > 0 or {:error, :invalid_expiry} do
      issued_at = DateTime.from_unix!(timestamp)

      {:ok,
       %{
         amount_sats: amount_sats,
         payment_hash: payment_hash,
         description: description,
         description_hash: description_hash,
         network: network,
         timestamp: timestamp,
         expiry_seconds: expiry_seconds,
         expires_at: DateTime.add(issued_at, expiry_seconds, :second),
         min_final_cltv_expiry: min_final_cltv_expiry,
         payee: payee,
         features: features
       }}
    else
      {:error, _reason} = error -> error
    end
  end

  defp validate_payment_secret(tags) do
    case fetch_tag(tags, 16) do
      :error ->
        :ok

      {:ok, _words} ->
        case required_hash(tags, 16, :payment_secret_missing) do
          {:ok, _secret} -> :ok
          error -> error
        end
    end
  end

  defp required_hash(tags, tag, missing_reason) do
    case fetch_tag(tags, tag) do
      {:ok, words} when length(words) == @payment_hash_length_bech32 ->
        decode_words(words, 32)

      {:ok, _value} ->
        {:error, {:invalid_tag_length, tag}}

      :error ->
        {:error, missing_reason}
    end
  end

  defp description_fields(tags) do
    description = fetch_tag(tags, @tag_description)
    description_hash = fetch_tag(tags, @tag_description_hash)

    cond do
      description != :error and description_hash != :error ->
        {:error, :description_missing_or_ambiguous}

      description == :error and description_hash == :error ->
        {:error, :description_missing_or_ambiguous}

      description_hash != :error ->
        case required_hash(tags, @tag_description_hash, :description_hash_missing) do
          {:ok, hash} -> {:ok, nil, hash}
          error -> error
        end

      true ->
        {:ok, words} = description

        with {:ok, bytes} <- decode_words(words, div(length(words) * 5, 8)),
             true <- String.valid?(bytes) or {:error, :invalid_description} do
          {:ok, bytes, nil}
        end
    end
  end

  defp optional_integer(tags, tag, default) do
    case fetch_tag(tags, tag) do
      :error ->
        {:ok, default}

      {:ok, []} ->
        {:error, {:invalid_tag_length, tag}}

      {:ok, words} when length(words) <= 11 ->
        {:ok, Enum.reduce(words, 0, &((&2 <<< 5) + &1))}

      {:ok, _value} ->
        {:error, {:invalid_tag_length, tag}}
    end
  end

  defp optional_payee(tags) do
    case fetch_tag(tags, @tag_payee) do
      :error ->
        {:ok, nil}

      {:ok, words} when length(words) == 53 ->
        with {:ok, <<prefix, _key_bytes::binary-size(32)>> = key} when prefix in [2, 3] <-
               decode_words(words, 33),
             {_x, _y} <- decompress_key(key) do
          {:ok, key}
        else
          _other -> {:error, :invalid_payee_key}
        end

      {:ok, _value} ->
        {:error, {:invalid_tag_length, @tag_payee}}
    end
  end

  defp optional_binary(tags, tag) do
    case fetch_tag(tags, tag) do
      :error -> {:ok, nil}
      {:ok, words} -> {:ok, words_to_bitstring(words)}
    end
  end

  defp fetch_tag(tags, tag) do
    case List.keyfind(tags, tag, 0) do
      {^tag, value} -> {:ok, value}
      nil -> :error
    end
  end

  defp decode_words(words, output_bytes) do
    bitstream = words_to_bitstring(words)
    output_bits = output_bytes * 8
    padding_bits = bit_size(bitstream) - output_bits

    if padding_bits >= 0 and padding_bits < 5 do
      <<output::binary-size(^output_bytes), padding::bitstring-size(^padding_bits)>> = bitstream

      if padding == <<0::size(padding_bits)>>,
        do: {:ok, output},
        else: {:error, :non_zero_padding}
    else
      {:error, :invalid_tag_length}
    end
  end

  defp words_to_bitstring(words) do
    Enum.reduce(words, <<>>, fn word, acc -> <<acc::bitstring, word::size(5)>> end)
  end

  defp signed_message(hrp, signed_words) do
    bits = words_to_bitstring(signed_words)
    padding = rem(8 - rem(bit_size(bits), 8), 8)
    padded = <<bits::bitstring, 0::size(padding)>>
    hrp <> padded
  end

  defp verify_signature(hrp, signed_words, signature_words, expected_payee) do
    with {:ok, <<r::unsigned-big-256, s::unsigned-big-256, recovery_id>>} <-
           decode_words(signature_words, 65),
         :ok <- validate_signature_scalars(r, s, recovery_id),
         {:ok, public_key} <- recover_public_key(hrp, signed_words, r, s, recovery_id),
         :ok <- validate_recovered_payee(public_key, expected_payee),
         :ok <- verify_recovered_signature(hrp, signed_words, r, s, public_key) do
      :ok
    else
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_signature}
    end
  end

  defp validate_signature_scalars(r, s, recovery_id) do
    if r > 0 and r < @secp256k1_n and s > 0 and s < @secp256k1_n and recovery_id in 0..3,
      do: :ok,
      else: {:error, :invalid_signature}
  end

  defp recover_public_key(hrp, signed_words, r, s, recovery_id) do
    x = r + div(recovery_id, 2) * @secp256k1_n

    if x >= @secp256k1_p do
      {:error, :invalid_signature}
    else
      case point_from_x(x, Bitwise.band(recovery_id, 1)) do
        {:ok, point} ->
          message = signed_message(hrp, signed_words)
          digest = :crypto.hash(:sha256, message)
          e = :binary.decode_unsigned(digest)
          r_inverse = mod_inverse(r, @secp256k1_n)

          numerator =
            point_subtract(
              point_multiply(point, s),
              point_multiply({@secp256k1_gx, @secp256k1_gy, 1}, e)
            )

          case affine_point(point_multiply(numerator, r_inverse)) do
            {:ok, public_key} -> {:ok, public_key}
            :infinity -> {:error, :invalid_signature}
          end

        :error ->
          {:error, :invalid_signature}
      end
    end
  end

  defp validate_recovered_payee(_public_key, nil), do: :ok

  defp validate_recovered_payee({x, y}, <<prefix, encoded_x::binary-size(32)>>) do
    if :binary.decode_unsigned(encoded_x) == x and prefix == 2 + Bitwise.band(y, 1),
      do: :ok,
      else: {:error, :payee_signature_mismatch}
  end

  defp verify_recovered_signature(hrp, signed_words, r, s, {x, y}) do
    message = signed_message(hrp, signed_words)
    signature = der_signature(r, s)
    public_key = <<4, x::unsigned-big-256, y::unsigned-big-256>>

    if :crypto.verify(:ecdsa, :sha256, message, signature, [public_key, :secp256k1]),
      do: :ok,
      else: {:error, :invalid_signature}
  end

  defp der_signature(r, s) do
    r_der = der_integer(r)
    s_der = der_integer(s)
    <<48, byte_size(r_der) + byte_size(s_der), r_der::binary, s_der::binary>>
  end

  defp der_integer(value) do
    bytes = :binary.encode_unsigned(value)
    padded = if :binary.first(bytes) >= 128, do: <<0, bytes::binary>>, else: bytes
    <<2, byte_size(padded), padded::binary>>
  end

  defp decompress_key(<<prefix, encoded_x::binary-size(32)>>) when prefix in [2, 3] do
    case point_from_x(:binary.decode_unsigned(encoded_x), prefix - 2) do
      {:ok, point} -> elem(affine_point(point), 1)
      :error -> nil
    end
  end

  defp point_from_x(x, parity) when x >= 0 and x < @secp256k1_p do
    alpha = Integer.mod(x * x * x + 7, @secp256k1_p)
    beta = mod_pow(alpha, div(@secp256k1_p + 1, 4), @secp256k1_p)

    if Integer.mod(beta * beta, @secp256k1_p) == alpha do
      y = if Bitwise.band(beta, 1) == parity, do: beta, else: @secp256k1_p - beta
      {:ok, {x, y, 1}}
    else
      :error
    end
  end

  defp point_from_x(_other_x, _other_parity), do: :error

  defp point_subtract(point, other), do: point_add(point, point_negate(other))

  defp point_negate(:infinity), do: :infinity
  defp point_negate({x, y, z}), do: {x, @secp256k1_p - y, z}

  defp point_multiply(:infinity, _scalar), do: :infinity

  defp point_multiply(point, scalar) when scalar < @secp256k1_n do
    scalar
    |> :binary.encode_unsigned()
    |> scalar_bits()
    |> Enum.reduce(:infinity, fn bit, acc ->
      doubled = point_double(acc)
      if bit == 1, do: point_add(doubled, point), else: doubled
    end)
  end

  defp scalar_bits(binary), do: for(<<bit::size(1) <- binary>>, do: bit)

  defp point_double(:infinity), do: :infinity
  defp point_double({_x, 0, _z}), do: :infinity

  defp point_double({x, y, z}) do
    yy = mod_p(y * y)
    s = mod_p(4 * x * yy)
    m = mod_p(3 * x * x)
    x3 = mod_p(m * m - 2 * s)
    y3 = mod_p(m * (s - x3) - 8 * yy * yy)
    z3 = mod_p(2 * y * z)
    {x3, y3, z3}
  end

  defp point_add(:infinity, point), do: point
  defp point_add(point, :infinity), do: point

  defp point_add({x1, y1, z1}, {x2, y2, z2}) do
    z1_squared = mod_p(z1 * z1)
    z2_squared = mod_p(z2 * z2)
    u1 = mod_p(x1 * z2_squared)
    u2 = mod_p(x2 * z1_squared)
    s1 = mod_p(y1 * z2 * z2_squared)
    s2 = mod_p(y2 * z1 * z1_squared)

    cond do
      u1 == u2 and s1 != s2 -> :infinity
      u1 == u2 -> point_double({x1, y1, z1})
      true -> point_add_unequal({x1, y1, z1}, {z1, z2}, {u1, s1}, {u2, s2})
    end
  end

  defp point_add_unequal({_x1, _y1, z1}, {z1, z2}, {u1, s1}, {u2, s2}) do
    h = mod_p(u2 - u1)
    r = mod_p(s2 - s1)
    h_squared = mod_p(h * h)
    u1_h_squared = mod_p(u1 * h_squared)
    x3 = mod_p(r * r - h * h_squared - 2 * u1_h_squared)
    y3 = mod_p(r * (u1_h_squared - x3) - s1 * h * h_squared)
    z3 = mod_p(h * z1 * z2)
    {x3, y3, z3}
  end

  defp affine_point(:infinity), do: :infinity

  defp affine_point({x, y, z}) do
    if z == 0 do
      :infinity
    else
      inverse = mod_inverse(z, @secp256k1_p)
      inverse_squared = mod_p(inverse * inverse)
      {:ok, {mod_p(x * inverse_squared), mod_p(y * inverse_squared * inverse)}}
    end
  end

  defp mod_p(value), do: Integer.mod(value, @secp256k1_p)

  defp mod_inverse(0, _modulus), do: 0
  defp mod_inverse(value, modulus), do: mod_pow(value, modulus - 2, modulus)

  defp mod_pow(base, exponent, modulus) do
    do_mod_pow(Integer.mod(base, modulus), exponent, modulus, 1)
  end

  defp do_mod_pow(_base, 0, _modulus, acc), do: acc

  defp do_mod_pow(base, exponent, modulus, acc) do
    next_acc = if Bitwise.band(exponent, 1) == 1, do: Integer.mod(acc * base, modulus), else: acc
    do_mod_pow(Integer.mod(base * base, modulus), exponent >>> 1, modulus, next_acc)
  end

  defp validate_expiry(invoice, %DateTime{} = now, safety_window) when is_integer(safety_window) do
    remaining = DateTime.diff(invoice.expires_at, now, :second)

    cond do
      remaining <= 0 -> {:error, :expired}
      remaining < safety_window -> {:error, :expiring_too_soon}
      true -> :ok
    end
  end

  defp data_chars(rest) when is_binary(rest) do
    parts = String.split(rest, "1")

    case parts do
      [_only_one_part] ->
        {:error, :malformed_payload}

      _many ->
        payload = List.last(parts)

        if byte_size(payload) > 6 do
          chars = String.to_charlist(payload)
          {:ok, Enum.drop(chars, -6)}
        else
          {:error, :malformed_payload}
        end
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

  defp find_payment_hash(stream) when length(stream) < 7, do: {:error, :payload_too_short}
  defp find_payment_hash(stream), do: walk_tagged_fields(Enum.drop(stream, 7))
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
  defp find_description_hash(stream) when length(stream) < 7, do: {:error, :payload_too_short}
  defp find_description_hash(stream), do: walk_description_hash_fields(Enum.drop(stream, 7))
  defp walk_description_hash_fields([]), do: {:error, :description_hash_missing}

  defp walk_description_hash_fields([tag, len_hi, len_lo | rest]) do
    length_bech32 = len_hi * 32 + len_lo

    cond do
      length(rest) < length_bech32 ->
        {:error, :payload_truncated}

      tag == @tag_description_hash and length_bech32 == @payment_hash_length_bech32 ->
        {:ok, five_bit_to_binary(Enum.take(rest, length_bech32), 256)}

      true ->
        walk_description_hash_fields(Enum.drop(rest, length_bech32))
    end
  end

  defp walk_description_hash_fields(_other), do: {:error, :description_hash_missing}

  defp five_bit_to_binary(chars, output_bits) do
    bitstream = Enum.reduce(chars, <<>>, fn value, acc -> <<acc::bitstring, value::size(5)>> end)
    <<hash::bitstring-size(^output_bits), _padding::bitstring>> = bitstream
    <<hash::bitstring>>
  end
end
