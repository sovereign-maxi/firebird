defmodule FireBird.InvoiceTest do
  use ExUnit.Case, async: true

  alias FireBird.Invoice

  setup do
    preimage = :crypto.strong_rand_bytes(32)
    payment_hash = :crypto.hash(:sha256, preimage)

    invoice =
      Invoice.new(
        payment_hash: payment_hash,
        bolt11: "lnbc1000u1pdummy",
        amount_sats: 1_000,
        created_at: DateTime.utc_now(),
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        description: "test invoice"
      )

    %{invoice: invoice, preimage: preimage, payment_hash: payment_hash}
  end

  describe "new/1" do
    test "creates a pending invoice", %{invoice: invoice} do
      assert invoice.status == :pending
      assert invoice.preimage == nil
      assert invoice.paid_at == nil
    end

    test "enforces required keys" do
      assert_raise ArgumentError, fn ->
        Invoice.new(payment_hash: <<0::256>>)
      end
    end
  end

  describe "mark_paid/2" do
    test "transitions pending → paid with valid preimage", %{invoice: invoice, preimage: preimage} do
      assert {:ok, paid} = Invoice.mark_paid(invoice, preimage)
      assert paid.status == :paid
      assert paid.preimage == preimage
      assert %DateTime{} = paid.paid_at
    end

    test "rejects invalid preimage", %{invoice: invoice} do
      bad_preimage = :crypto.strong_rand_bytes(32)
      assert {:error, :invalid_preimage} = Invoice.mark_paid(invoice, bad_preimage)
    end

    test "rejects marking a paid invoice", %{invoice: invoice, preimage: preimage} do
      {:ok, paid} = Invoice.mark_paid(invoice, preimage)
      assert {:error, :not_pending} = Invoice.mark_paid(paid, preimage)
    end

    test "rejects marking an expired invoice", %{invoice: invoice, preimage: preimage} do
      {:ok, expired} = Invoice.mark_expired(invoice)
      assert {:error, :not_pending} = Invoice.mark_paid(expired, preimage)
    end
  end

  describe "mark_expired/1" do
    test "transitions pending → expired", %{invoice: invoice} do
      assert {:ok, expired} = Invoice.mark_expired(invoice)
      assert expired.status == :expired
    end

    test "rejects marking a paid invoice as expired", %{invoice: invoice, preimage: preimage} do
      {:ok, paid} = Invoice.mark_paid(invoice, preimage)
      assert {:error, :not_pending} = Invoice.mark_expired(paid)
    end

    test "is idempotent on error for already expired", %{invoice: invoice} do
      {:ok, expired} = Invoice.mark_expired(invoice)
      assert {:error, :not_pending} = Invoice.mark_expired(expired)
    end
  end

  describe "expired?/1" do
    test "returns false for future expiry", %{invoice: invoice} do
      refute Invoice.expired?(invoice)
    end

    test "returns true for past expiry" do
      invoice =
        Invoice.new(
          payment_hash: :crypto.strong_rand_bytes(32),
          bolt11: "lnbc1u1pdummy",
          amount_sats: 100,
          created_at: DateTime.add(DateTime.utc_now(), -7200, :second),
          expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)
        )

      assert Invoice.expired?(invoice)
    end
  end

  describe "Inspect protocol" do
    test "redacts preimage when present", %{invoice: invoice, preimage: preimage} do
      {:ok, paid} = Invoice.mark_paid(invoice, preimage)
      inspected = inspect(paid)
      assert inspected =~ "**REDACTED**"
      refute inspected =~ Base.encode16(preimage)
    end

    test "shows nil preimage as-is", %{invoice: invoice} do
      inspected = inspect(invoice)
      refute inspected =~ "**REDACTED**"
    end
  end
end
