defmodule FireBird.Bolt11Test do
  use ExUnit.Case, async: true

  alias FireBird.Bolt11

  describe "parse_amount/1" do
    test "parses millibitcoin (m) multiplier" do
      assert {:ok, 100_000} = Bolt11.parse_amount("lnbc1m1pdummy")
      assert {:ok, 500_000} = Bolt11.parse_amount("lnbc5m1pdummy")
    end

    test "parses microbitcoin (u) multiplier" do
      assert {:ok, 100} = Bolt11.parse_amount("lnbc1u1pdummy")
      assert {:ok, 10_000} = Bolt11.parse_amount("lnbc100u1pdummy")
    end

    test "parses nanobitcoin (n) multiplier" do
      assert {:ok, 150} = Bolt11.parse_amount("lnbc1500n1pdummy")
      assert {:ok, 1} = Bolt11.parse_amount("lnbc10n1pdummy")
    end

    test "parses picobitcoin (p) multiplier" do
      assert {:ok, 1} = Bolt11.parse_amount("lnbc10000p1pdummy")
    end

    test "parses whole BTC amount" do
      assert {:ok, 100_000_000} = Bolt11.parse_amount("lnbc11pdummy")
      assert {:ok, 200_000_000} = Bolt11.parse_amount("lnbc21pdummy")
    end

    test "handles testnet prefix" do
      assert {:ok, 100_000} = Bolt11.parse_amount("lntb1m1pdummy")
    end

    test "handles regtest prefix" do
      assert {:ok, 100_000} = Bolt11.parse_amount("lnbcrt1m1pdummy")
    end

    test "handles signet prefix" do
      assert {:ok, 100_000} = Bolt11.parse_amount("lntbs1m1pdummy")
    end

    test "is case insensitive" do
      assert {:ok, 100_000} = Bolt11.parse_amount("LNBC1M1PDUMMY")
    end

    test "returns error for invalid prefix" do
      assert {:error, :invalid_prefix} = Bolt11.parse_amount("lnxx1m1pdummy")
    end

    test "returns error for missing amount" do
      assert {:error, :invalid_amount} = Bolt11.parse_amount("lnbc")
    end

    test "returns error for non-string input" do
      assert {:error, :invalid_input} = Bolt11.parse_amount(123)
      assert {:error, :invalid_input} = Bolt11.parse_amount(nil)
    end

    test "parses zero-amount (no amount) invoices as 0 sats" do
      assert {:ok, 0} = Bolt11.parse_amount("lnbc1pdummy")
      assert {:ok, 0} = Bolt11.parse_amount("lntb1pdummy")
      assert {:ok, 0} = Bolt11.parse_amount("lnbcrt1pdummy")
    end

    test "returns error for sub-satoshi picobitcoin amounts" do
      assert {:error, :sub_satoshi} = Bolt11.parse_amount("lnbc1p1pdummy")
      assert {:error, :sub_satoshi} = Bolt11.parse_amount("lnbc99p1pdummy")
    end

    test "accepts picobitcoin amounts >= 1 sat" do
      assert {:ok, 1} = Bolt11.parse_amount("lnbc10000p1pdummy")
    end

    test "rejects picobitcoin amounts with msat-precision remainder" do
      # 1_999_000 pBTC = 199.9 sats — has msat precision the mint
      # can't represent. Previous implementation silently floored to
      # 199, so upstream callers that enforced parsed_sats ==
      # paid_sats lost the remainder per melt.
      assert {:error, :sub_satoshi} = Bolt11.parse_amount("lnbc1999000p1pdummy")
    end

    test "accepts whole-satoshi picobitcoin amounts" do
      # 2_000_000 pBTC = 200.0 sats — clean, no remainder.
      assert {:ok, 200} = Bolt11.parse_amount("lnbc2000000p1pdummy")
    end
  end

  describe "payment_hash/1" do
    # Canonical BOLT11 spec test vector — the `p` tagged field decodes
    # to 0001020304050607080900010203040506070809000102030405060708090102.
    @spec_invoice "lnbc2500u1pvjluezpp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqdq5xysxxatsyp3k7enxv4jsxqzpuaztrnwngzn3kdzw5hydlzf03qdgm2hdq27cqv3agm2awhz5se903vruatfhq77w3ls4evs3ch9zw97j25emudupq63nyw24cg27h2rspfj9srp"
    @spec_hash Base.decode16!(
                 "0001020304050607080900010203040506070809000102030405060708090102",
                 case: :lower
               )

    test "extracts the 32-byte payment hash from the spec test vector" do
      assert {:ok, hash} = Bolt11.payment_hash(@spec_invoice)
      assert hash == @spec_hash
      assert byte_size(hash) == 32
    end

    test "is case insensitive" do
      upper = String.upcase(@spec_invoice)
      assert {:ok, @spec_hash} = Bolt11.payment_hash(upper)
    end

    test "returns error for invalid prefix" do
      assert {:error, :invalid_prefix} = Bolt11.payment_hash("lnxx1abc")
    end

    test "returns error for non-string input" do
      assert {:error, :invalid_input} = Bolt11.payment_hash(nil)
      assert {:error, :invalid_input} = Bolt11.payment_hash(123)
    end

    test "returns error for malformed payload (no separator)" do
      assert {:error, :malformed_payload} = Bolt11.payment_hash("lnbcabc")
    end

    test "returns error when the payment_hash tagged field is missing" do
      # Amount-only prefix with checksum but no `p` tag.
      assert {:error, _reason} = Bolt11.payment_hash("lnbc1m1pdummy" <> String.duplicate("q", 40))
    end

    test "extracts description_hash when the invoice carries an `h` tag (synthesized)" do
      # Hand-rolled bolt11 with the tag-23 payload set to a known
      # 32-byte value. Firebird doesn't verify bech32 checksum, so
      # the parser round-trips a synthetic invoice unchanged.
      dh = :crypto.hash(:sha256, "lnurl-pay metadata test")
      invoice = build_synthetic_invoice(amount_sats: 100_000, description_hash: dh)

      assert {:ok, ^dh} = Bolt11.description_hash(invoice)
    end

    test "description_hash/1 refuses invoices with no `h` tag (spec vector has `d`)" do
      # The walker either runs off the end at a tagged-field
      # boundary (`:description_hash_missing`) or finds a truncated
      # trailing field (`:payload_truncated`). Both correctly refuse.
      assert {:error, reason} = Bolt11.description_hash(@spec_invoice)
      assert reason in [:description_hash_missing, :payload_truncated]
    end

    test "handles amounts containing the digit 1 (last-1 separator rule)" do
      # bech32's separator is the LAST `1` — splitting on the first `1`
      # cuts through amount digits like `10u`, `1u`, or `2510u`. Same
      # tagged-field payload as the spec vector, three different HRPs:
      # all three MUST return the spec hash.
      hrp_and_data =
        "1pvjluezpp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqdq5xysxxatsyp3k7enxv4jsxqzpuaztrnwngzn3kdzw5hydlzf03qdgm2hdq27cqv3agm2awhz5se903vruatfhq77w3ls4evs3ch9zw97j25emudupq63nyw24cg27h2rspfj9srp"

      for amount_prefix <- ["lnbc1u", "lnbc10u", "lnbc2510u"] do
        assert {:ok, @spec_hash} = Bolt11.payment_hash(amount_prefix <> hrp_and_data),
               "expected spec-hash extraction from #{amount_prefix}<data> after last-1 split fix"
      end
    end
  end

  # --- Synthetic invoice builder (test support) ---
  #
  # Emits amount + payment_hash tag + description_hash tag + filler
  # signature. Firebird's parser doesn't verify bech32 checksum, so
  # a hand-rolled stream round-trips cleanly through parse_amount/1
  # + payment_hash/1 + description_hash/1. Not a general-purpose
  # encoder.

  @bech32_alphabet ~c"qpzry9x8gf2tvdw0s3jn54khce6mua7l"
  @tag_hash_length_bech32 52

  defp build_synthetic_invoice(opts) do
    amount_sats = Keyword.fetch!(opts, :amount_sats)
    payment_hash = Keyword.get(opts, :payment_hash, :crypto.strong_rand_bytes(32))
    description_hash = Keyword.get(opts, :description_hash, :crypto.strong_rand_bytes(32))

    amount_prefix = Integer.to_string(amount_sats * 10_000) <> "p"
    timestamp = String.duplicate("q", 7)

    p_header = tag_header(1)
    p_body = binary_to_bech32(payment_hash, @tag_hash_length_bech32)

    h_header = tag_header(23)
    h_body = binary_to_bech32(description_hash, @tag_hash_length_bech32)

    sig = String.duplicate("q", 104)

    "lnbc" <> amount_prefix <> "1" <> timestamp <> p_header <> p_body <> h_header <> h_body <> sig
  end

  defp tag_header(tag_value) do
    len_hi = div(@tag_hash_length_bech32, 32)
    len_lo = rem(@tag_hash_length_bech32, 32)
    <<char(tag_value), char(len_hi), char(len_lo)>>
  end

  defp binary_to_bech32(binary, output_chars) do
    pad_bits = output_chars * 5 - bit_size(binary)
    padded = <<binary::bitstring, 0::size(pad_bits)>>
    for <<v::size(5) <- padded>>, into: "", do: <<char(v)>>
  end

  defp char(index) when index in 0..31, do: Enum.at(@bech32_alphabet, index)
end
