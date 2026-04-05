defmodule FireBird.FeesTest do
  use ExUnit.Case, async: true

  alias FireBird.Fees

  describe "calculate/2" do
    test "applies PPM rate" do
      # 1_000_000 sats * 1000 ppm = 1000 sats
      assert Fees.calculate(1_000_000) == 1000
    end

    test "uses ceiling division" do
      # 1 sat * 1000 ppm = 0.001 sats, ceil = 1
      assert Fees.calculate(1) == 1
    end

    test "clamps to minimum fee" do
      assert Fees.calculate(1, fee_ppm: 1, fee_min_sats: 5) == 5
    end

    test "clamps to maximum fee" do
      assert Fees.calculate(1_000_000_000, fee_ppm: 10_000, fee_max_sats: 500) == 500
    end

    test "accepts custom PPM" do
      assert Fees.calculate(1_000_000, fee_ppm: 5000) == 5000
    end

    test "handles small amounts" do
      assert Fees.calculate(1, fee_ppm: 1000) == 1
    end

    test "edge case: amount equals 1 million (1 PPM = 1)" do
      assert Fees.calculate(1_000_000, fee_ppm: 1, fee_min_sats: 0) == 1
    end
  end

  describe "deposit_fee/2" do
    test "delegates to calculate" do
      assert Fees.deposit_fee(1_000_000) == Fees.calculate(1_000_000)
    end

    test "accepts config overrides" do
      opts = [fee_ppm: 500, fee_min_sats: 10]
      assert Fees.deposit_fee(1_000_000, opts) == Fees.calculate(1_000_000, opts)
    end
  end

  describe "withdrawal_fee/2" do
    test "delegates to calculate" do
      assert Fees.withdrawal_fee(1_000_000) == Fees.calculate(1_000_000)
    end

    test "accepts config overrides" do
      opts = [fee_ppm: 2000, fee_max_sats: 50]
      assert Fees.withdrawal_fee(1_000_000, opts) == Fees.calculate(1_000_000, opts)
    end
  end
end
