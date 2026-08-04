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
end
