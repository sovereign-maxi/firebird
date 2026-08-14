defmodule FireBird.ManagerTest do
  use ExUnit.Case, async: false

  alias FireBird.Manager
  alias FireBird.MockClient

  @moduletag :scenario

  setup do
    n = System.unique_integer([:positive])
    table = :"invoice_mgr_test_#{n}"
    pubsub = :"invoice_mgr_pubsub_#{n}"
    client_name = :"invoice_mgr_client_#{n}"

    start_supervised!({Registry, keys: :duplicate, name: pubsub})
    start_supervised!({MockClient, name: client_name}, id: client_name)

    # Very high poll interval so we control polling manually
    pid =
      start_supervised!(
        {Manager,
         [
           client: {MockClient, client_name},
           pubsub: pubsub,
           table_name: table,
           poll_interval: 600_000,
           name: :"invoice_mgr_#{n}"
         ]}
      )

    %{pid: pid, table: table, pubsub: pubsub, client: client_name}
  end

  describe "init/1" do
    test "creates ETS table", %{table: table} do
      assert :ets.whereis(table) != :undefined
    end
  end

  describe "track/2 and lookup/2" do
    test "stores invoice and lookup finds it", %{pid: pid, table: table} do
      invoice = build_test_invoice()
      assert :ok = Manager.track(pid, invoice)
      assert {:ok, ^invoice} = Manager.lookup(table, invoice.payment_hash)
    end
  end

  describe "list/1" do
    test "returns all tracked invoices", %{pid: pid, table: table} do
      inv1 = build_test_invoice()
      inv2 = build_test_invoice()
      Manager.track(pid, inv1)
      Manager.track(pid, inv2)

      listed = Manager.list(table)
      hashes = listed |> Enum.map(& &1.payment_hash) |> MapSet.new()
      assert MapSet.member?(hashes, inv1.payment_hash)
      assert MapSet.member?(hashes, inv2.payment_hash)
    end
  end

  describe "poll" do
    test "expired invoice publishes InvoiceExpired and updates ETS", ctx do
      invoice = build_test_invoice(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
      Manager.track(ctx.pid, invoice)
      Registry.register(ctx.pubsub, :invoice, [])

      send(ctx.pid, :poll)
      :sys.get_state(ctx.pid)

      assert_receive {FireBird.PubSub, :invoice,
                      %FireBird.Events.InvoiceExpired{
                        payment_hash: payment_hash
                      }}

      assert payment_hash == invoice.payment_hash
      assert {:ok, updated} = Manager.lookup(ctx.table, invoice.payment_hash)
      assert updated.status == :expired
    end

    test "expired-but-paid invoice is confirmed, not expired (poll before expire)", ctx do
      preimage = :crypto.strong_rand_bytes(32)
      payment_hash = :crypto.hash(:sha256, preimage)
      preimage_hex = Base.encode16(preimage, case: :lower)

      invoice =
        build_test_invoice(
          payment_hash: payment_hash,
          expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
        )

      Manager.track(ctx.pid, invoice)
      Registry.register(ctx.pubsub, :invoice, [])

      MockClient.set_response(
        ctx.client,
        :get_incoming_payment,
        {:ok, %{"isPaid" => true, "preimage" => preimage_hex, "receivedSat" => 1_000}}
      )

      send(ctx.pid, :poll)
      :sys.get_state(ctx.pid)

      assert_receive {FireBird.PubSub, :invoice,
                      %FireBird.Events.InvoicePaid{payment_hash: ^payment_hash}}

      assert {:ok, updated} = Manager.lookup(ctx.table, payment_hash)
      assert updated.status == :paid
    end

    test "paid invoice publishes InvoicePaid and updates ETS", ctx do
      preimage = :crypto.strong_rand_bytes(32)
      payment_hash = :crypto.hash(:sha256, preimage)
      preimage_hex = Base.encode16(preimage, case: :lower)

      invoice = build_test_invoice(payment_hash: payment_hash)
      Manager.track(ctx.pid, invoice)
      Registry.register(ctx.pubsub, :invoice, [])

      MockClient.set_response(
        ctx.client,
        :get_incoming_payment,
        {:ok, %{"isPaid" => true, "preimage" => preimage_hex, "receivedSat" => 1_000}}
      )

      send(ctx.pid, :poll)
      :sys.get_state(ctx.pid)

      assert_receive {FireBird.PubSub, :invoice,
                      %FireBird.Events.InvoicePaid{
                        payment_hash: ^payment_hash
                      }}

      assert {:ok, updated} = Manager.lookup(ctx.table, payment_hash)
      assert updated.status == :paid
    end

    test "pending invoice with empty preimage is unchanged", ctx do
      invoice = build_test_invoice()
      Manager.track(ctx.pid, invoice)

      MockClient.set_response(ctx.client, :get_incoming_payment, {:ok, %{"preimage" => ""}})

      send(ctx.pid, :poll)
      :sys.get_state(ctx.pid)

      assert {:ok, unchanged} = Manager.lookup(ctx.table, invoice.payment_hash)
      assert unchanged.status == :pending
    end

    test "client error does not crash GenServer", ctx do
      invoice = build_test_invoice()
      Manager.track(ctx.pid, invoice)

      MockClient.set_response(ctx.client, :get_incoming_payment, {:error, :timeout})

      send(ctx.pid, :poll)
      state = :sys.get_state(ctx.pid)
      assert is_struct(state, Manager)
      assert Process.alive?(ctx.pid)
    end

    test "invalid preimage hex does not crash GenServer", ctx do
      invoice = build_test_invoice()
      Manager.track(ctx.pid, invoice)

      MockClient.set_response(ctx.client, :get_incoming_payment, {:ok, %{"preimage" => "ZZZZ"}})

      send(ctx.pid, :poll)
      :sys.get_state(ctx.pid)

      assert Process.alive?(ctx.pid)
      assert {:ok, unchanged} = Manager.lookup(ctx.table, invoice.payment_hash)
      assert unchanged.status == :pending
    end
  end

  describe "poll — preimage is proof of payment (isPaid flag is ignored)" do
    test "preimage present with isPaid=false confirms payment", ctx do
      preimage = :crypto.strong_rand_bytes(32)
      payment_hash = :crypto.hash(:sha256, preimage)
      preimage_hex = Base.encode16(preimage, case: :lower)

      invoice = build_test_invoice(payment_hash: payment_hash)
      Manager.track(ctx.pid, invoice)
      Registry.register(ctx.pubsub, :invoice, [])

      MockClient.set_response(
        ctx.client,
        :get_incoming_payment,
        {:ok, %{"isPaid" => false, "preimage" => preimage_hex, "receivedSat" => 1_000}}
      )

      send(ctx.pid, :poll)
      :sys.get_state(ctx.pid)

      assert_receive {FireBird.PubSub, :invoice,
                      %FireBird.Events.InvoicePaid{payment_hash: ^payment_hash}}

      assert {:ok, paid} = Manager.lookup(ctx.table, payment_hash)
      assert paid.status == :paid
    end

    test "preimage present without isPaid key confirms payment", ctx do
      preimage = :crypto.strong_rand_bytes(32)
      payment_hash = :crypto.hash(:sha256, preimage)
      preimage_hex = Base.encode16(preimage, case: :lower)

      invoice = build_test_invoice(payment_hash: payment_hash)
      Manager.track(ctx.pid, invoice)
      Registry.register(ctx.pubsub, :invoice, [])

      MockClient.set_response(
        ctx.client,
        :get_incoming_payment,
        {:ok, %{"preimage" => preimage_hex, "receivedSat" => 1_000}}
      )

      send(ctx.pid, :poll)
      :sys.get_state(ctx.pid)

      assert_receive {FireBird.PubSub, :invoice,
                      %FireBird.Events.InvoicePaid{payment_hash: ^payment_hash}}

      assert {:ok, paid} = Manager.lookup(ctx.table, payment_hash)
      assert paid.status == :paid
    end

    test "isPaid=true with valid preimage confirms payment", ctx do
      preimage = :crypto.strong_rand_bytes(32)
      payment_hash = :crypto.hash(:sha256, preimage)
      preimage_hex = Base.encode16(preimage, case: :lower)

      invoice = build_test_invoice(payment_hash: payment_hash)
      Manager.track(ctx.pid, invoice)
      Registry.register(ctx.pubsub, :invoice, [])

      MockClient.set_response(
        ctx.client,
        :get_incoming_payment,
        {:ok, %{"isPaid" => true, "preimage" => preimage_hex, "receivedSat" => 1_000}}
      )

      send(ctx.pid, :poll)
      :sys.get_state(ctx.pid)

      assert_receive {FireBird.PubSub, :invoice,
                      %FireBird.Events.InvoicePaid{payment_hash: ^payment_hash}}

      assert {:ok, paid} = Manager.lookup(ctx.table, payment_hash)
      assert paid.status == :paid
      assert paid.preimage == preimage
    end

    test "wrong preimage does NOT confirm payment", ctx do
      preimage = :crypto.strong_rand_bytes(32)
      payment_hash = :crypto.hash(:sha256, preimage)
      wrong_preimage = :crypto.strong_rand_bytes(32)
      wrong_hex = Base.encode16(wrong_preimage, case: :lower)

      invoice = build_test_invoice(payment_hash: payment_hash)
      Manager.track(ctx.pid, invoice)
      Registry.register(ctx.pubsub, :invoice, [])

      MockClient.set_response(
        ctx.client,
        :get_incoming_payment,
        {:ok, %{"isPaid" => true, "preimage" => wrong_hex, "receivedSat" => 1_000}}
      )

      send(ctx.pid, :poll)
      :sys.get_state(ctx.pid)

      refute_receive {FireBird.PubSub, :invoice, %FireBird.Events.InvoicePaid{}}
      assert {:ok, unchanged} = Manager.lookup(ctx.table, payment_hash)
      assert unchanged.status == :pending
    end

    test "no preimage does NOT confirm payment regardless of isPaid", ctx do
      preimage = :crypto.strong_rand_bytes(32)
      payment_hash = :crypto.hash(:sha256, preimage)

      invoice = build_test_invoice(payment_hash: payment_hash)
      Manager.track(ctx.pid, invoice)
      Registry.register(ctx.pubsub, :invoice, [])

      MockClient.set_response(
        ctx.client,
        :get_incoming_payment,
        {:ok, %{"isPaid" => true}}
      )

      send(ctx.pid, :poll)
      :sys.get_state(ctx.pid)

      refute_receive {FireBird.PubSub, :invoice, %FireBird.Events.InvoicePaid{}}
      assert {:ok, unchanged} = Manager.lookup(ctx.table, payment_hash)
      assert unchanged.status == :pending
    end
  end

  describe "poll — receivedSat validation" do
    test "underpaid invoice is NOT confirmed", ctx do
      preimage = :crypto.strong_rand_bytes(32)
      payment_hash = :crypto.hash(:sha256, preimage)
      preimage_hex = Base.encode16(preimage, case: :lower)

      invoice = build_test_invoice(payment_hash: payment_hash, amount_sats: 10_000)
      Manager.track(ctx.pid, invoice)
      Registry.register(ctx.pubsub, :invoice, [])

      MockClient.set_response(
        ctx.client,
        :get_incoming_payment,
        {:ok, %{"isPaid" => true, "preimage" => preimage_hex, "receivedSat" => 5_000}}
      )

      send(ctx.pid, :poll)
      :sys.get_state(ctx.pid)

      refute_receive {FireBird.PubSub, :invoice, %FireBird.Events.InvoicePaid{}}
      assert {:ok, unchanged} = Manager.lookup(ctx.table, payment_hash)
      assert unchanged.status == :pending
    end

    test "exact amount is confirmed", ctx do
      preimage = :crypto.strong_rand_bytes(32)
      payment_hash = :crypto.hash(:sha256, preimage)
      preimage_hex = Base.encode16(preimage, case: :lower)

      invoice = build_test_invoice(payment_hash: payment_hash, amount_sats: 10_000)
      Manager.track(ctx.pid, invoice)
      Registry.register(ctx.pubsub, :invoice, [])

      MockClient.set_response(
        ctx.client,
        :get_incoming_payment,
        {:ok, %{"isPaid" => true, "preimage" => preimage_hex, "receivedSat" => 10_000}}
      )

      send(ctx.pid, :poll)
      :sys.get_state(ctx.pid)

      assert_receive {FireBird.PubSub, :invoice,
                      %FireBird.Events.InvoicePaid{payment_hash: ^payment_hash}}

      assert {:ok, paid} = Manager.lookup(ctx.table, payment_hash)
      assert paid.status == :paid
    end

    test "overpaid invoice is confirmed", ctx do
      preimage = :crypto.strong_rand_bytes(32)
      payment_hash = :crypto.hash(:sha256, preimage)
      preimage_hex = Base.encode16(preimage, case: :lower)

      invoice = build_test_invoice(payment_hash: payment_hash, amount_sats: 10_000)
      Manager.track(ctx.pid, invoice)
      Registry.register(ctx.pubsub, :invoice, [])

      MockClient.set_response(
        ctx.client,
        :get_incoming_payment,
        {:ok, %{"isPaid" => true, "preimage" => preimage_hex, "receivedSat" => 15_000}}
      )

      send(ctx.pid, :poll)
      :sys.get_state(ctx.pid)

      assert_receive {FireBird.PubSub, :invoice,
                      %FireBird.Events.InvoicePaid{payment_hash: ^payment_hash}}
    end

    test "missing receivedSat field fails closed (no auto-confirm)", ctx do
      # Security-relevant: crediting the invoice at the EXPECTED amount
      # when phoenixd doesn't tell us what actually landed is a free-mint
      # vector under any scenario where phoenixd is compromised or the
      # API changes shape. We refuse to confirm.
      preimage = :crypto.strong_rand_bytes(32)
      payment_hash = :crypto.hash(:sha256, preimage)
      preimage_hex = Base.encode16(preimage, case: :lower)

      invoice = build_test_invoice(payment_hash: payment_hash, amount_sats: 10_000)
      Manager.track(ctx.pid, invoice)
      Registry.register(ctx.pubsub, :invoice, [])

      MockClient.set_response(
        ctx.client,
        :get_incoming_payment,
        {:ok, %{"isPaid" => true, "preimage" => preimage_hex, "receivedSat" => 1_000}}
      )

      send(ctx.pid, :poll)
      :sys.get_state(ctx.pid)

      refute_receive {FireBird.PubSub, :invoice, %FireBird.Events.InvoicePaid{}}
      assert {:ok, unchanged} = Manager.lookup(ctx.table, payment_hash)
      assert unchanged.status == :pending
    end
  end

  describe "poll — preimage length validation" do
    test "short preimage (not 32 bytes) does NOT confirm", ctx do
      short_preimage = :crypto.strong_rand_bytes(16)
      real_preimage = :crypto.strong_rand_bytes(32)
      payment_hash = :crypto.hash(:sha256, real_preimage)
      short_hex = Base.encode16(short_preimage, case: :lower)

      invoice = build_test_invoice(payment_hash: payment_hash)
      Manager.track(ctx.pid, invoice)
      Registry.register(ctx.pubsub, :invoice, [])

      MockClient.set_response(
        ctx.client,
        :get_incoming_payment,
        {:ok, %{"isPaid" => true, "preimage" => short_hex, "receivedSat" => 1_000}}
      )

      send(ctx.pid, :poll)
      :sys.get_state(ctx.pid)

      refute_receive {FireBird.PubSub, :invoice, %FireBird.Events.InvoicePaid{}}
      assert {:ok, unchanged} = Manager.lookup(ctx.table, payment_hash)
      assert unchanged.status == :pending
    end
  end

  describe "check_payment/2" do
    test "triggers immediate payment confirmation for pending invoice", ctx do
      preimage = :crypto.strong_rand_bytes(32)
      payment_hash = :crypto.hash(:sha256, preimage)
      preimage_hex = Base.encode16(preimage, case: :lower)

      invoice = build_test_invoice(payment_hash: payment_hash)
      Manager.track(ctx.pid, invoice)
      Registry.register(ctx.pubsub, :invoice, [])

      MockClient.set_response(
        ctx.client,
        :get_incoming_payment,
        {:ok, %{"isPaid" => true, "preimage" => preimage_hex, "receivedSat" => 1_000}}
      )

      Manager.check_payment(ctx.pid, payment_hash)
      # cast is async, wait for processing
      :sys.get_state(ctx.pid)

      assert_receive {FireBird.PubSub, :invoice,
                      %FireBird.Events.InvoicePaid{payment_hash: ^payment_hash}}

      assert {:ok, updated} = Manager.lookup(ctx.table, payment_hash)
      assert updated.status == :paid
    end

    test "ignores non-pending invoice", ctx do
      # Create and expire an invoice
      invoice = build_test_invoice(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
      Manager.track(ctx.pid, invoice)

      send(ctx.pid, :poll)
      :sys.get_state(ctx.pid)

      assert {:ok, expired} = Manager.lookup(ctx.table, invoice.payment_hash)
      assert expired.status == :expired

      Registry.register(ctx.pubsub, :invoice, [])

      # check_payment on an expired invoice should be a no-op
      Manager.check_payment(ctx.pid, invoice.payment_hash)
      :sys.get_state(ctx.pid)

      refute_receive {FireBird.PubSub, :invoice, _}
    end

    test "ignores unknown payment hash", ctx do
      Registry.register(ctx.pubsub, :invoice, [])
      unknown_hash = :crypto.strong_rand_bytes(32)

      Manager.check_payment(ctx.pid, unknown_hash)
      :sys.get_state(ctx.pid)

      refute_receive {FireBird.PubSub, :invoice, _}
      assert Process.alive?(ctx.pid)
    end
  end

  describe "config validation" do
    test "rejects poll_interval: 0" do
      n = System.unique_integer([:positive])
      pubsub = :"inv_mgr_val_pubsub_#{n}"
      client_name = :"inv_mgr_val_client_#{n}"
      start_supervised!({Registry, keys: :duplicate, name: pubsub}, id: pubsub)
      start_supervised!({MockClient, name: client_name}, id: {MockClient, client_name})

      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: msg}, _stacktrace}} =
               Manager.start_link(
                 client: {MockClient, client_name},
                 pubsub: pubsub,
                 table_name: :"inv_mgr_val_#{n}",
                 poll_interval: 0,
                 name: :"inv_mgr_val_srv_#{n}"
               )

      assert msg =~ "poll_interval must be a positive integer"
    end
  end

  describe "ETS cleanup on terminate" do
    test "deletes ETS table on stop", %{table: table} do
      assert :ets.whereis(table) != :undefined
      stop_supervised!(Manager)
      assert :ets.whereis(table) == :undefined
    end
  end

  describe "terminal cleanup" do
    test "cleans up paid invoices after retention period" do
      n = System.unique_integer([:positive])
      table = :"inv_cleanup_test_#{n}"
      pubsub = :"inv_cleanup_pubsub_#{n}"
      client_name = :"inv_cleanup_client_#{n}"

      start_supervised!({Registry, keys: :duplicate, name: pubsub}, id: pubsub)
      start_supervised!({MockClient, name: client_name}, id: {MockClient, client_name})

      pid =
        start_supervised!(
          {Manager,
           [
             client: {MockClient, client_name},
             pubsub: pubsub,
             table_name: table,
             poll_interval: 600_000,
             retention_ms: 1,
             cleanup_interval: 600_000,
             name: :"inv_cleanup_#{n}"
           ]},
          id: {Manager, n}
        )

      # Create a paid invoice with paid_at in the past
      preimage = :crypto.strong_rand_bytes(32)
      payment_hash = :crypto.hash(:sha256, preimage)
      invoice = build_test_invoice(payment_hash: payment_hash)
      Manager.track(pid, invoice)

      # Mark it paid via mock
      MockClient.set_response(
        client_name,
        :get_incoming_payment,
        {:ok,
         %{
           "isPaid" => true,
           "preimage" => Base.encode16(preimage, case: :lower),
           "receivedSat" => 1_000
         }}
      )

      send(pid, :poll)
      :sys.get_state(pid)

      assert {:ok, paid} = Manager.lookup(table, payment_hash)
      assert paid.status == :paid

      # Wait for retention to expire, then trigger cleanup
      Process.sleep(10)
      send(pid, :cleanup)
      :sys.get_state(pid)

      assert {:error, :not_found} = Manager.lookup(table, payment_hash)
    end

    test "retains paid invoices within retention period" do
      n = System.unique_integer([:positive])
      table = :"inv_retain_test_#{n}"
      pubsub = :"inv_retain_pubsub_#{n}"
      client_name = :"inv_retain_client_#{n}"

      start_supervised!({Registry, keys: :duplicate, name: pubsub}, id: {Registry, n})
      start_supervised!({MockClient, name: client_name}, id: {MockClient, n})

      pid =
        start_supervised!(
          {Manager,
           [
             client: {MockClient, client_name},
             pubsub: pubsub,
             table_name: table,
             poll_interval: 600_000,
             retention_ms: 600_000,
             cleanup_interval: 600_000,
             name: :"inv_retain_#{n}"
           ]},
          id: {Manager, n}
        )

      preimage = :crypto.strong_rand_bytes(32)
      payment_hash = :crypto.hash(:sha256, preimage)
      invoice = build_test_invoice(payment_hash: payment_hash)
      Manager.track(pid, invoice)

      MockClient.set_response(
        client_name,
        :get_incoming_payment,
        {:ok,
         %{
           "isPaid" => true,
           "preimage" => Base.encode16(preimage, case: :lower),
           "receivedSat" => 1_000
         }}
      )

      send(pid, :poll)
      :sys.get_state(pid)

      send(pid, :cleanup)
      :sys.get_state(pid)

      # Should still be there — retention hasn't expired
      assert {:ok, _paid} = Manager.lookup(table, payment_hash)
    end
  end

  describe "catch-all handle_info" do
    test "unexpected messages do not crash the GenServer", %{pid: pid} do
      send(pid, :totally_unexpected)
      :sys.get_state(pid)
      assert Process.alive?(pid)
    end
  end

  defp build_test_invoice(opts \\ []) do
    payment_hash = Keyword.get_lazy(opts, :payment_hash, fn -> :crypto.strong_rand_bytes(32) end)
    now = DateTime.utc_now()

    FireBird.Invoice.new(
      payment_hash: payment_hash,
      bolt11: "lnbc1000u1ptest#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}",
      amount_sats: Keyword.get(opts, :amount_sats, 1_000),
      created_at: Keyword.get(opts, :created_at, now),
      expires_at: Keyword.get(opts, :expires_at, DateTime.add(now, 3600, :second))
    )
  end
end
