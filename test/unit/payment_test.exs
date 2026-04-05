defmodule FireBird.PaymentTest do
  use ExUnit.Case, async: true

  alias FireBird.Payment

  setup do
    payment =
      Payment.new(
        payment_hash: :crypto.strong_rand_bytes(32),
        bolt11: "lnbc1000u1pdummy",
        amount_sats: 1_000,
        created_at: DateTime.utc_now()
      )

    %{payment: payment}
  end

  describe "new/1" do
    test "creates a pending payment with defaults", %{payment: payment} do
      assert payment.status == :pending
      assert payment.attempt == 0
      assert payment.max_attempts == 3
      assert payment.preimage == nil
      assert payment.fee_sats == nil
    end

    test "accepts custom max_attempts" do
      payment =
        Payment.new(
          payment_hash: :crypto.strong_rand_bytes(32),
          bolt11: "lnbc1u1pdummy",
          amount_sats: 100,
          created_at: DateTime.utc_now(),
          max_attempts: 5
        )

      assert payment.max_attempts == 5
    end

    test "enforces required keys" do
      assert_raise ArgumentError, fn ->
        Payment.new(payment_hash: <<0::256>>)
      end
    end
  end

  describe "mark_in_flight/1" do
    test "transitions pending → in_flight", %{payment: payment} do
      assert {:ok, in_flight} = Payment.mark_in_flight(payment)
      assert in_flight.status == :in_flight
      assert in_flight.attempt == 1
    end

    test "transitions retrying → in_flight" do
      payment =
        Payment.new(
          payment_hash: :crypto.strong_rand_bytes(32),
          bolt11: "lnbc1u1pdummy",
          amount_sats: 100,
          created_at: DateTime.utc_now()
        )

      {:ok, in_flight} = Payment.mark_in_flight(payment)
      {:ok, failed} = Payment.mark_failed(in_flight, "timeout")
      assert failed.status == :retrying

      {:ok, retry_flight} = Payment.mark_in_flight(failed)
      assert retry_flight.status == :in_flight
      assert retry_flight.attempt == 2
    end

    test "rejects in_flight → in_flight", %{payment: payment} do
      {:ok, in_flight} = Payment.mark_in_flight(payment)
      assert {:error, :not_sendable} = Payment.mark_in_flight(in_flight)
    end

    test "rejects succeeded → in_flight", %{payment: payment} do
      {:ok, in_flight} = Payment.mark_in_flight(payment)
      preimage = :crypto.strong_rand_bytes(32)
      {:ok, succeeded} = Payment.mark_succeeded(in_flight, preimage, 10)
      assert {:error, :not_sendable} = Payment.mark_in_flight(succeeded)
    end
  end

  describe "mark_succeeded/3" do
    test "transitions in_flight → succeeded", %{payment: payment} do
      {:ok, in_flight} = Payment.mark_in_flight(payment)
      preimage = :crypto.strong_rand_bytes(32)

      assert {:ok, succeeded} = Payment.mark_succeeded(in_flight, preimage, 42)
      assert succeeded.status == :succeeded
      assert succeeded.preimage == preimage
      assert succeeded.fee_sats == 42
      assert %DateTime{} = succeeded.completed_at
    end

    test "rejects non-in-flight", %{payment: payment} do
      preimage = :crypto.strong_rand_bytes(32)
      assert {:error, :not_in_flight} = Payment.mark_succeeded(payment, preimage, 0)
    end
  end

  describe "mark_failed/2" do
    test "transitions to retrying when attempts remain", %{payment: payment} do
      {:ok, in_flight} = Payment.mark_in_flight(payment)
      assert {:ok, failed} = Payment.mark_failed(in_flight, "route not found")
      assert failed.status == :retrying
      assert failed.last_error == "route not found"
      assert failed.completed_at == nil
    end

    test "transitions to exhausted when max attempts reached" do
      payment =
        Payment.new(
          payment_hash: :crypto.strong_rand_bytes(32),
          bolt11: "lnbc1u1pdummy",
          amount_sats: 100,
          created_at: DateTime.utc_now(),
          max_attempts: 1
        )

      {:ok, in_flight} = Payment.mark_in_flight(payment)
      assert {:ok, exhausted} = Payment.mark_failed(in_flight, "final failure")
      assert exhausted.status == :exhausted
      assert %DateTime{} = exhausted.completed_at
    end

    test "rejects non-in-flight", %{payment: payment} do
      assert {:error, :not_in_flight} = Payment.mark_failed(payment, "oops")
    end
  end

  describe "next_retry_delay/1" do
    test "returns base delay for first attempt" do
      payment = %Payment{
        payment_hash: <<0::256>>,
        bolt11: "x",
        amount_sats: 1,
        status: :retrying,
        created_at: DateTime.utc_now(),
        attempt: 1,
        max_attempts: 3
      }

      assert Payment.next_retry_delay(payment) == 1_000
    end

    test "doubles with each attempt" do
      make = fn attempt ->
        %Payment{
          payment_hash: <<0::256>>,
          bolt11: "x",
          amount_sats: 1,
          status: :retrying,
          created_at: DateTime.utc_now(),
          attempt: attempt,
          max_attempts: 5
        }
      end

      assert Payment.next_retry_delay(make.(1)) == 1_000
      assert Payment.next_retry_delay(make.(2)) == 2_000
      assert Payment.next_retry_delay(make.(3)) == 4_000
    end

    test "caps at 30 seconds" do
      payment = %Payment{
        payment_hash: <<0::256>>,
        bolt11: "x",
        amount_sats: 1,
        status: :retrying,
        created_at: DateTime.utc_now(),
        attempt: 20,
        max_attempts: 25
      }

      assert Payment.next_retry_delay(payment) == 30_000
    end
  end

  describe "retriable?/1" do
    test "true for retrying status" do
      payment = %Payment{
        payment_hash: <<0::256>>,
        bolt11: "x",
        amount_sats: 1,
        status: :retrying,
        created_at: DateTime.utc_now(),
        attempt: 1,
        max_attempts: 3
      }

      assert Payment.retriable?(payment)
    end

    test "false for other statuses", %{payment: payment} do
      refute Payment.retriable?(payment)
    end
  end
end
