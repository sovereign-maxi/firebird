defmodule FireBird.EventsTest do
  use ExUnit.Case, async: true

  alias FireBird.Events.{
    InvoiceExpired,
    InvoicePaid,
    LiquidityCritical,
    LiquidityLow,
    LiquidityRecovered,
    PaymentExhausted,
    PaymentFailed,
    PaymentSent
  }

  describe "InvoicePaid" do
    test "enforces required keys" do
      assert_raise ArgumentError, fn -> struct!(InvoicePaid, []) end
    end

    test "defaults version to 1" do
      event = %InvoicePaid{
        payment_hash: <<0::256>>,
        amount_sats: 1000,
        received_sats: 1000,
        paid_at: DateTime.utc_now()
      }

      assert event.version == 1
    end
  end

  describe "InvoiceExpired" do
    test "enforces required keys" do
      assert_raise ArgumentError, fn -> struct!(InvoiceExpired, []) end
    end

    test "defaults version to 1" do
      event = %InvoiceExpired{
        payment_hash: <<0::256>>,
        amount_sats: 1000,
        expired_at: DateTime.utc_now()
      }

      assert event.version == 1
    end
  end

  describe "PaymentSent" do
    test "enforces required keys" do
      assert_raise ArgumentError, fn -> struct!(PaymentSent, []) end
    end

    test "defaults version to 1" do
      event = %PaymentSent{
        payment_hash: <<0::256>>,
        amount_sats: 1000,
        fee_sats: 10,
        preimage: <<1::256>>
      }

      assert event.version == 1
    end
  end

  describe "PaymentFailed" do
    test "enforces required keys" do
      assert_raise ArgumentError, fn -> struct!(PaymentFailed, []) end
    end

    test "defaults version to 1" do
      event = %PaymentFailed{
        payment_hash: <<0::256>>,
        amount_sats: 1000,
        reason: "timeout",
        attempt: 1
      }

      assert event.version == 1
    end
  end

  describe "PaymentExhausted" do
    test "enforces required keys" do
      assert_raise ArgumentError, fn -> struct!(PaymentExhausted, []) end
    end

    test "defaults version to 1" do
      event = %PaymentExhausted{
        payment_hash: <<0::256>>,
        amount_sats: 1000,
        reason: "no route",
        attempts: 3
      }

      assert event.version == 1
    end
  end

  describe "LiquidityLow" do
    test "enforces required keys" do
      assert_raise ArgumentError, fn -> struct!(LiquidityLow, []) end
    end

    test "defaults version to 1" do
      event = %LiquidityLow{balance_sats: 50_000, threshold_sats: 100_000}
      assert event.version == 1
    end
  end

  describe "LiquidityCritical" do
    test "enforces required keys" do
      assert_raise ArgumentError, fn -> struct!(LiquidityCritical, []) end
    end

    test "defaults version to 1" do
      event = %LiquidityCritical{balance_sats: 5_000, threshold_sats: 10_000}
      assert event.version == 1
    end
  end

  describe "LiquidityRecovered" do
    test "enforces required keys" do
      assert_raise ArgumentError, fn -> struct!(LiquidityRecovered, []) end
    end

    test "defaults version to 1" do
      event = %LiquidityRecovered{balance_sats: 2_000_000, threshold_sats: 1_000_000}
      assert event.version == 1
    end
  end
end
