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
end
