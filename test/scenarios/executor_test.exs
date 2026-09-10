defmodule FireBird.ExecutorTest do
  use ExUnit.Case, async: false

  alias FireBird.Executor
  alias FireBird.MockClient
  alias FireBird.MockWAL
  alias FireBird.Payment

  @moduletag :scenario

  setup do
    n = System.unique_integer([:positive])
    table = :"pay_exec_test_#{n}"
    pubsub = :"pay_exec_pubsub_#{n}"
    client_name = :"pay_exec_client_#{n}"

    start_supervised!({Registry, keys: :duplicate, name: pubsub})
    start_supervised!({MockClient, name: client_name}, id: client_name)

    pid =
      start_supervised!(
        {Executor,
         [
           client: {MockClient, client_name},
           pubsub: pubsub,
           table_name: table,
           max_concurrent: 2,
           name: :"pay_exec_#{n}"
         ]}
      )

    %{pid: pid, table: table, pubsub: pubsub, client: client_name}
  end

  describe "submit and lookup" do
    test "executes payment and stores in ETS as succeeded", ctx do
      payment = build_test_payment()
      preimage = :crypto.strong_rand_bytes(32)
      preimage_hex = Base.encode16(preimage, case: :lower)

      MockClient.set_response(
        ctx.client,
        :pay_invoice,
        {:ok, %{"preimage" => preimage_hex, "fees" => 10}}
      )

      assert :ok = Executor.submit(ctx.pid, payment)

      # Poll until async task completes
      FireBirdHelpers.await_condition(fn ->
        match?(
          {:ok, %{status: :succeeded}},
          Executor.lookup(ctx.table, payment.payment_hash)
        )
      end)

      assert {:ok, result} = Executor.lookup(ctx.table, payment.payment_hash)
      assert result.status == :succeeded
    end

    test "at capacity returns error", ctx do
      # Use blocking response to fill slots
      MockClient.set_response(ctx.client, :pay_invoice, fn ->
        Process.sleep(5_000)
        {:error, :timeout}
      end)

      p1 = build_test_payment()
      p2 = build_test_payment()
      p3 = build_test_payment()

      assert :ok = Executor.submit(ctx.pid, p1)
      assert :ok = Executor.submit(ctx.pid, p2)
      assert {:error, :at_capacity} = Executor.submit(ctx.pid, p3)
    end

    test "lookup finds payment in ETS", ctx do
      payment = build_test_payment()

      MockClient.set_response(ctx.client, :pay_invoice, fn ->
        Process.sleep(5_000)
        {:ok, %{"preimage" => "aa", "fees" => 0}}
      end)

      Executor.submit(ctx.pid, payment)

      # submit is a GenServer.call — ETS insert happens before reply
      assert {:ok, found} = Executor.lookup(ctx.table, payment.payment_hash)
      assert found.status == :in_flight
    end
  end

  describe "success flow" do
    test "publishes PaymentSent event", ctx do
      Registry.register(ctx.pubsub, :payment, [])
      payment = build_test_payment()
      preimage = :crypto.strong_rand_bytes(32)
      preimage_hex = Base.encode16(preimage, case: :lower)

      MockClient.set_response(
        ctx.client,
        :pay_invoice,
        {:ok, %{"preimage" => preimage_hex, "fees" => 5}}
      )

      Executor.submit(ctx.pid, payment)

      assert_receive {FireBird.PubSub, :payment,
                      %FireBird.Events.PaymentSent{
                        payment_hash: payment_hash,
                        fee_sats: 5
                      }},
                     1_000

      assert payment_hash == payment.payment_hash
    end
  end

  describe "phoenixd response format" do
    test "handles paymentPreimage + routingFeeSat keys", ctx do
      Registry.register(ctx.pubsub, :payment, [])
      payment = build_test_payment()
      preimage = :crypto.strong_rand_bytes(32)
      preimage_hex = Base.encode16(preimage, case: :lower)

      MockClient.set_response(
        ctx.client,
        :pay_invoice,
        {:ok,
         %{
           "recipientAmountSat" => 1000,
           "routingFeeSat" => 42,
           "paymentId" => "c20efa78-da1c-4f1e-b70f-0c32523fbcd4",
           "paymentHash" => Base.encode16(payment.payment_hash, case: :lower),
           "paymentPreimage" => preimage_hex
         }}
      )

      Executor.submit(ctx.pid, payment)

      assert_receive {FireBird.PubSub, :payment,
                      %FireBird.Events.PaymentSent{
                        payment_hash: _,
                        fee_sats: 42,
                        preimage: ^preimage
                      }},
                     1_000
    end
  end

  describe "failure and retry (retryable errors)" do
    test "publishes PaymentFailed, then retry leads to success", ctx do
      Registry.register(ctx.pubsub, :payment, [])
      payment = build_test_payment(max_attempts: 3)

      # First attempt returns a structured phoenixd error that classifies
      # as :retryable (temporary route/liquidity problem — the payment
      # provably did NOT happen, retrying may succeed). Second attempt
      # succeeds.
      preimage = :crypto.strong_rand_bytes(32)
      preimage_hex = Base.encode16(preimage, case: :lower)

      call_count = :counters.new(1, [:atomics])

      MockClient.set_response(ctx.client, :pay_invoice, fn ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if count == 0 do
          {:error, {:phoenixd_error, :route_not_found, "no route"}}
        else
          {:ok, %{"preimage" => preimage_hex, "fees" => 2}}
        end
      end)

      Executor.submit(ctx.pid, payment)

      assert_receive {FireBird.PubSub, :payment, %FireBird.Events.PaymentFailed{}}, 1_000
      assert_receive {FireBird.PubSub, :payment, %FireBird.Events.PaymentSent{}}, 5_000
    end

    test "exhaustion publishes PaymentExhausted", ctx do
      Registry.register(ctx.pubsub, :payment, [])
      payment = build_test_payment(max_attempts: 1)

      MockClient.set_response(
        ctx.client,
        :pay_invoice,
        {:error, {:phoenixd_error, :route_not_found, "no route"}}
      )

      Executor.submit(ctx.pid, payment)

      assert_receive {FireBird.PubSub, :payment,
                      %FireBird.Events.PaymentExhausted{
                        attempts: 1
                      }},
                     1_000
    end
  end

  describe "unknown-outcome errors (fail-closed)" do
    test "HTTP timeout publishes PaymentUnknown, NOT PaymentFailed/Exhausted", ctx do
      Registry.register(ctx.pubsub, :payment, [])
      payment = build_test_payment(max_attempts: 3)

      MockClient.set_response(ctx.client, :pay_invoice, {:error, :timeout})

      Executor.submit(ctx.pid, payment)

      assert_receive {FireBird.PubSub, :payment, %FireBird.Events.PaymentUnknown{}}, 1_000
      refute_receive {FireBird.PubSub, :payment, %FireBird.Events.PaymentFailed{}}, 200
      refute_receive {FireBird.PubSub, :payment, %FireBird.Events.PaymentExhausted{}}, 200
    end

    test "5xx server error publishes PaymentUnknown", ctx do
      Registry.register(ctx.pubsub, :payment, [])
      payment = build_test_payment(max_attempts: 3)

      MockClient.set_response(ctx.client, :pay_invoice, {:error, {:http_error, 502, "Bad Gateway"}})

      Executor.submit(ctx.pid, payment)

      assert_receive {FireBird.PubSub, :payment, %FireBird.Events.PaymentUnknown{}}, 1_000
    end

    test "4xx with no node-side payment record publishes PaymentExhausted", ctx do
      Registry.register(ctx.pubsub, :payment, [])
      payment = build_test_payment(max_attempts: 3)

      MockClient.set_response(ctx.client, :pay_invoice, {:error, {:http_error, 400, "Bad Request"}})
      # The 4xx confirmation lookup finds no settled payment on the
      # node — releasing the reservation is provably safe.
      MockClient.set_response(
        ctx.client,
        :get_outgoing_payment_by_hash,
        {:error, {:http_error, 404, "not found"}}
      )

      Executor.submit(ctx.pid, payment)

      # Definitive-failure release path — one Exhausted event, no
      # Failed/retry ladder.
      assert_receive {FireBird.PubSub, :payment, %FireBird.Events.PaymentExhausted{}}, 1_000
      refute_receive {FireBird.PubSub, :payment, %FireBird.Events.PaymentFailed{}}, 200
    end

    test "4xx but node shows payment SETTLED publishes PaymentUnknown, never releases", ctx do
      Registry.register(ctx.pubsub, :payment, [])
      payment = build_test_payment(max_attempts: 3)

      MockClient.set_response(ctx.client, :pay_invoice, {:error, {:http_error, 400, "Bad Request"}})
      # The confirmation lookup shows the invoice settled out-of-band
      # (operator remsh, state loss + resubmit). Release = double-spend.
      MockClient.set_response(ctx.client, :get_outgoing_payment_by_hash, {:ok, %{"isPaid" => true}})

      Executor.submit(ctx.pid, payment)

      assert_receive {FireBird.PubSub, :payment, %FireBird.Events.PaymentUnknown{}}, 1_000
      refute_receive {FireBird.PubSub, :payment, %FireBird.Events.PaymentExhausted{}}, 200
    end

    test "4xx with pending node-side record publishes PaymentUnknown", ctx do
      Registry.register(ctx.pubsub, :payment, [])
      payment = build_test_payment(max_attempts: 3)

      MockClient.set_response(ctx.client, :pay_invoice, {:error, {:http_error, 400, "Bad Request"}})

      MockClient.set_response(
        ctx.client,
        :get_outgoing_payment_by_hash,
        {:ok, %{"isPaid" => false, "completedAt" => nil}}
      )

      Executor.submit(ctx.pid, payment)

      assert_receive {FireBird.PubSub, :payment, %FireBird.Events.PaymentUnknown{}}, 1_000
      refute_receive {FireBird.PubSub, :payment, %FireBird.Events.PaymentExhausted{}}, 200
    end
  end

  describe "submit-side idempotency" do
    test "rejects duplicate submit while an earlier one is in-flight", ctx do
      Registry.register(ctx.pubsub, :payment, [])
      payment = build_test_payment()

      # Slow response so the first submit stays in-flight long enough
      # for the duplicate check to fire.
      me = self()

      MockClient.set_response(ctx.client, :pay_invoice, fn ->
        send(me, :first_call_started)
        Process.sleep(200)

        {:ok,
         %{"preimage" => Base.encode16(:crypto.strong_rand_bytes(32), case: :lower), "fees" => 1}}
      end)

      assert :ok = Executor.submit(ctx.pid, payment)
      assert_receive :first_call_started, 500

      # Second submit with the SAME payment_hash while the first is
      # still executing must be rejected — otherwise we'd fire a
      # second /payinvoice against the same invoice.
      assert {:error, {:duplicate, {:in_flight, _status}}} =
               Executor.submit(ctx.pid, payment)

      # Let the first one finish.
      assert_receive {FireBird.PubSub, :payment, %FireBird.Events.PaymentSent{}}, 2_000
    end

    test "rejects submit for a payment left in :unknown state", ctx do
      Registry.register(ctx.pubsub, :payment, [])
      payment = build_test_payment()

      MockClient.set_response(ctx.client, :pay_invoice, {:error, :timeout})
      assert :ok = Executor.submit(ctx.pid, payment)
      assert_receive {FireBird.PubSub, :payment, %FireBird.Events.PaymentUnknown{}}, 1_000

      # An unknown-outcome payment may still settle on Lightning.
      # A resubmit for the same hash must be rejected until the
      # operator reconciles.
      assert {:error, {:duplicate, {:already_terminal, :unknown}}} =
               Executor.submit(ctx.pid, payment)
    end
  end

  describe "ensure_integer robustness" do
    test "handles string fees from API", ctx do
      Registry.register(ctx.pubsub, :payment, [])
      payment = build_test_payment()
      preimage = :crypto.strong_rand_bytes(32)
      preimage_hex = Base.encode16(preimage, case: :lower)

      MockClient.set_response(
        ctx.client,
        :pay_invoice,
        {:ok, %{"preimage" => preimage_hex, "fees" => "10"}}
      )

      Executor.submit(ctx.pid, payment)

      assert_receive {FireBird.PubSub, :payment, %FireBird.Events.PaymentSent{fee_sats: 10}},
                     1_000
    end

    test "handles float fees from API", ctx do
      Registry.register(ctx.pubsub, :payment, [])
      payment = build_test_payment()
      preimage = :crypto.strong_rand_bytes(32)
      preimage_hex = Base.encode16(preimage, case: :lower)

      MockClient.set_response(
        ctx.client,
        :pay_invoice,
        {:ok, %{"preimage" => preimage_hex, "fees" => 5.8}}
      )

      Executor.submit(ctx.pid, payment)

      assert_receive {FireBird.PubSub, :payment, %FireBird.Events.PaymentSent{fee_sats: 5}},
                     1_000
    end

    test "handles non-numeric string fees gracefully", ctx do
      Registry.register(ctx.pubsub, :payment, [])
      payment = build_test_payment()
      preimage = :crypto.strong_rand_bytes(32)
      preimage_hex = Base.encode16(preimage, case: :lower)

      MockClient.set_response(
        ctx.client,
        :pay_invoice,
        {:ok, %{"preimage" => preimage_hex, "fees" => "garbage"}}
      )

      Executor.submit(ctx.pid, payment)

      assert_receive {FireBird.PubSub, :payment, %FireBird.Events.PaymentSent{fee_sats: 0}},
                     1_000
    end

    test "handles nil fees gracefully", ctx do
      Registry.register(ctx.pubsub, :payment, [])
      payment = build_test_payment()
      preimage = :crypto.strong_rand_bytes(32)
      preimage_hex = Base.encode16(preimage, case: :lower)

      MockClient.set_response(
        ctx.client,
        :pay_invoice,
        {:ok, %{"preimage" => preimage_hex, "fees" => nil}}
      )

      Executor.submit(ctx.pid, payment)

      assert_receive {FireBird.PubSub, :payment, %FireBird.Events.PaymentSent{fee_sats: 0}},
                     1_000
    end
  end

  describe "task crash" do
    test "handles task crash without GenServer crash", ctx do
      MockClient.set_response(ctx.client, :pay_invoice, fn ->
        raise "boom"
      end)

      payment = build_test_payment(max_attempts: 1)
      Executor.submit(ctx.pid, payment)

      # Poll until the crashed task result is processed
      FireBirdHelpers.await_condition(fn ->
        case Executor.lookup(ctx.table, payment.payment_hash) do
          {:ok, %{status: status}} when status != :in_flight -> true
          _other -> false
        end
      end)

      assert Process.alive?(ctx.pid)
    end
  end

  describe "terminate/2 WAL" do
    test "writes in-flight payments to WAL on terminate" do
      n = System.unique_integer([:positive])
      table = :"pay_exec_wal_#{n}"
      pubsub = :"pay_exec_wal_pubsub_#{n}"
      client_name = :"pay_exec_wal_client_#{n}"
      wal_name = :"pay_exec_wal_agent_#{n}"

      start_supervised!({Registry, keys: :duplicate, name: pubsub}, id: pubsub)
      start_supervised!({MockClient, name: client_name}, id: {MockClient, client_name})
      start_supervised!({MockWAL, name: wal_name}, id: wal_name)

      MockClient.set_response(client_name, :pay_invoice, fn ->
        Process.sleep(60_000)
        {:error, :timeout}
      end)

      {:ok, pid} =
        Executor.start_link(
          client: {MockClient, client_name},
          pubsub: pubsub,
          table_name: table,
          max_concurrent: 10,
          wal: {MockWAL, wal_name},
          name: :"pay_exec_wal_srv_#{n}"
        )

      payment = build_test_payment()
      Executor.submit(pid, payment)
      # submit is a call — task is spawned by the time it returns
      :sys.get_state(pid)

      GenServer.stop(pid, :normal)

      entries = MockWAL.entries(wal_name)
      assert length(entries) >= 1
      assert Enum.any?(entries, &(&1.payment_hash == payment.payment_hash))
    end
  end

  describe "WAL recovery" do
    test "recovered in-flight payments become :unknown and publish PaymentUnknown" do
      n = System.unique_integer([:positive])
      table = :"pay_recover_#{n}"
      pubsub = :"pay_recover_pubsub_#{n}"
      client_name = :"pay_recover_client_#{n}"
      wal_name = :"pay_recover_wal_#{n}"

      start_supervised!({Registry, keys: :duplicate, name: pubsub}, id: pubsub)
      start_supervised!({MockClient, name: client_name}, id: {MockClient, client_name})
      start_supervised!({MockWAL, name: wal_name}, id: wal_name)

      # Pre-populate WAL as if the VM crashed mid-flight.
      payment = build_test_payment(max_attempts: 3)
      in_flight = %{payment | status: :in_flight, attempt: 1}
      MockWAL.append(wal_name, in_flight)

      Registry.register(pubsub, :payment, [])

      pid =
        start_supervised!(
          {Executor,
           [
             client: {MockClient, client_name},
             pubsub: pubsub,
             table_name: table,
             max_concurrent: 10,
             wal: {MockWAL, wal_name},
             name: :"pay_recover_srv_#{n}"
           ]},
          id: {Executor, n}
        )

      # Recovery must NOT auto-retry — phoenixd may have already
      # settled the original request before the crash. Payment lands
      # as :unknown and PaymentUnknown fires so the caller holds
      # its reservation.
      FireBirdHelpers.await_condition(fn ->
        match?({:ok, %{status: :unknown}}, Executor.lookup(table, payment.payment_hash))
      end)

      assert_receive {FireBird.PubSub, :payment, %FireBird.Events.PaymentUnknown{}}, 1_000

      # And no pay_invoice call happened during recovery.
      assert MockClient.calls(client_name, :pay_invoice) == []

      assert {:ok, result} = Executor.lookup(table, payment.payment_hash)
      assert result.status == :unknown
      assert result.completed_at != nil

      stop_supervised!({Executor, n})
      assert Process.alive?(pid) == false
    end

    test "recovered :unknown payment rejects any duplicate submit until reconciled" do
      n = System.unique_integer([:positive])
      table = :"pay_dup_after_recover_#{n}"
      pubsub = :"pay_dup_after_recover_pubsub_#{n}"
      client_name = :"pay_dup_after_recover_client_#{n}"
      wal_name = :"pay_dup_after_recover_wal_#{n}"

      start_supervised!({Registry, keys: :duplicate, name: pubsub}, id: pubsub)
      start_supervised!({MockClient, name: client_name}, id: {MockClient, client_name})
      start_supervised!({MockWAL, name: wal_name}, id: wal_name)

      payment = build_test_payment(max_attempts: 3)
      in_flight = %{payment | status: :in_flight, attempt: 1}
      MockWAL.append(wal_name, in_flight)

      pid =
        start_supervised!(
          {Executor,
           [
             client: {MockClient, client_name},
             pubsub: pubsub,
             table_name: table,
             max_concurrent: 10,
             wal: {MockWAL, wal_name},
             name: :"pay_dup_after_recover_srv_#{n}"
           ]},
          id: {Executor, n}
        )

      FireBirdHelpers.await_condition(fn ->
        match?({:ok, %{status: :unknown}}, Executor.lookup(table, payment.payment_hash))
      end)

      # Submitting the same payment_hash while it's still :unknown
      # must be rejected — a resubmit could double-pay a payment
      # phoenixd may already have settled.
      assert {:error, {:duplicate, {:already_terminal, :unknown}}} =
               Executor.submit(pid, payment)
    end

    test "even a max-attempt payment recovers as :unknown, not :exhausted" do
      # The previous contract auto-exhausted anything already at
      # max_attempts. Under the fail-closed discipline, "we crashed
      # with this in flight" is always ambiguous regardless of
      # attempt count — exhaustion requires the retry ladder to
      # have completed cleanly, which it can't when the VM died.
      n = System.unique_integer([:positive])
      table = :"pay_exhaust_#{n}"
      pubsub = :"pay_exhaust_pubsub_#{n}"
      client_name = :"pay_exhaust_client_#{n}"
      wal_name = :"pay_exhaust_wal_#{n}"

      start_supervised!({Registry, keys: :duplicate, name: pubsub}, id: pubsub)
      start_supervised!({MockClient, name: client_name}, id: {MockClient, client_name})
      start_supervised!({MockWAL, name: wal_name}, id: wal_name)

      payment = build_test_payment(max_attempts: 2)
      in_flight = %{payment | status: :in_flight, attempt: 2}
      MockWAL.append(wal_name, in_flight)

      _pid =
        start_supervised!(
          {Executor,
           [
             client: {MockClient, client_name},
             pubsub: pubsub,
             table_name: table,
             max_concurrent: 10,
             wal: {MockWAL, wal_name},
             name: :"pay_exhaust_srv_#{n}"
           ]},
          id: {Executor, n}
        )

      FireBirdHelpers.await_condition(fn ->
        match?({:ok, %{status: :unknown}}, Executor.lookup(table, payment.payment_hash))
      end)

      assert {:ok, result} = Executor.lookup(table, payment.payment_hash)
      assert result.status == :unknown
      assert result.completed_at != nil
    end

    test "starts cleanly with empty WAL" do
      n = System.unique_integer([:positive])
      table = :"pay_empty_wal_#{n}"
      pubsub = :"pay_empty_wal_pubsub_#{n}"
      client_name = :"pay_empty_wal_client_#{n}"
      wal_name = :"pay_empty_wal_agent_#{n}"

      start_supervised!({Registry, keys: :duplicate, name: pubsub}, id: pubsub)
      start_supervised!({MockClient, name: client_name}, id: {MockClient, client_name})
      start_supervised!({MockWAL, name: wal_name}, id: wal_name)

      pid =
        start_supervised!(
          {Executor,
           [
             client: {MockClient, client_name},
             pubsub: pubsub,
             table_name: table,
             max_concurrent: 10,
             wal: {MockWAL, wal_name},
             name: :"pay_empty_wal_srv_#{n}"
           ]},
          id: {Executor, n}
        )

      assert Process.alive?(pid)
      assert :ets.tab2list(table) == []
    end
  end

  describe "terminal cleanup" do
    test "cleans up succeeded payments after retention period" do
      n = System.unique_integer([:positive])
      table = :"pay_cleanup_test_#{n}"
      pubsub = :"pay_cleanup_pubsub_#{n}"
      client_name = :"pay_cleanup_client_#{n}"

      start_supervised!({Registry, keys: :duplicate, name: pubsub}, id: pubsub)
      start_supervised!({MockClient, name: client_name}, id: {MockClient, n})

      preimage = :crypto.strong_rand_bytes(32)
      preimage_hex = Base.encode16(preimage, case: :lower)

      MockClient.set_response(
        client_name,
        :pay_invoice,
        {:ok, %{"preimage" => preimage_hex, "fees" => 1}}
      )

      pid =
        start_supervised!(
          {Executor,
           [
             client: {MockClient, client_name},
             pubsub: pubsub,
             table_name: table,
             max_concurrent: 10,
             retention_ms: 1,
             cleanup_interval: 600_000,
             name: :"pay_cleanup_#{n}"
           ]},
          id: {Executor, n}
        )

      payment = build_test_payment()
      Executor.submit(pid, payment)

      # Poll until async task completes
      FireBirdHelpers.await_condition(fn ->
        match?({:ok, %{status: :succeeded}}, Executor.lookup(table, payment.payment_hash))
      end)

      assert {:ok, result} = Executor.lookup(table, payment.payment_hash)
      assert result.status == :succeeded

      # Wait for retention to expire, then trigger cleanup
      Process.sleep(10)
      send(pid, :cleanup)
      :sys.get_state(pid)

      assert {:error, :not_found} = Executor.lookup(table, payment.payment_hash)
    end

    test "retains succeeded payments within retention period" do
      n = System.unique_integer([:positive])
      table = :"pay_retain_test_#{n}"
      pubsub = :"pay_retain_pubsub_#{n}"
      client_name = :"pay_retain_client_#{n}"

      start_supervised!({Registry, keys: :duplicate, name: pubsub}, id: {Registry, n})
      start_supervised!({MockClient, name: client_name}, id: {MockClient, {n, :retain}})

      preimage = :crypto.strong_rand_bytes(32)
      preimage_hex = Base.encode16(preimage, case: :lower)

      MockClient.set_response(
        client_name,
        :pay_invoice,
        {:ok, %{"preimage" => preimage_hex, "fees" => 1}}
      )

      pid =
        start_supervised!(
          {Executor,
           [
             client: {MockClient, client_name},
             pubsub: pubsub,
             table_name: table,
             max_concurrent: 10,
             retention_ms: 600_000,
             cleanup_interval: 600_000,
             name: :"pay_retain_#{n}"
           ]},
          id: {Executor, {n, :retain}}
        )

      payment = build_test_payment()
      Executor.submit(pid, payment)

      # Poll until async task completes
      FireBirdHelpers.await_condition(fn ->
        match?({:ok, %{status: :succeeded}}, Executor.lookup(table, payment.payment_hash))
      end)

      send(pid, :cleanup)
      :sys.get_state(pid)

      # Should still be there — retention hasn't expired
      assert {:ok, _result} = Executor.lookup(table, payment.payment_hash)
    end
  end

  describe "config validation" do
    test "rejects max_concurrent: 0" do
      n = System.unique_integer([:positive])
      pubsub = :"pay_exec_val_pubsub_#{n}"
      client_name = :"pay_exec_val_client_#{n}"
      start_supervised!({Registry, keys: :duplicate, name: pubsub}, id: pubsub)
      start_supervised!({MockClient, name: client_name}, id: {MockClient, client_name})

      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: msg}, _stacktrace}} =
               Executor.start_link(
                 client: {MockClient, client_name},
                 pubsub: pubsub,
                 table_name: :"pay_exec_val_#{n}",
                 max_concurrent: 0,
                 name: :"pay_exec_val_srv_#{n}"
               )

      assert msg =~ "max_concurrent must be a positive integer"
    end

    test "rejects negative max_concurrent" do
      n = System.unique_integer([:positive])
      pubsub = :"pay_exec_neg_pubsub_#{n}"
      client_name = :"pay_exec_neg_client_#{n}"
      start_supervised!({Registry, keys: :duplicate, name: pubsub}, id: pubsub)
      start_supervised!({MockClient, name: client_name}, id: {MockClient, client_name})

      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: msg}, _stacktrace}} =
               Executor.start_link(
                 client: {MockClient, client_name},
                 pubsub: pubsub,
                 table_name: :"pay_exec_neg_#{n}",
                 max_concurrent: -1,
                 name: :"pay_exec_neg_srv_#{n}"
               )

      assert msg =~ "max_concurrent must be a positive integer"
    end
  end

  describe "ETS cleanup on terminate" do
    test "deletes ETS table on stop", ctx do
      assert :ets.whereis(ctx.table) != :undefined
      stop_supervised!(Executor)
      assert :ets.whereis(ctx.table) == :undefined
    end
  end

  describe "catch-all handle_info" do
    test "unexpected messages do not crash the GenServer", ctx do
      send(ctx.pid, :totally_unexpected)
      :sys.get_state(ctx.pid)
      assert Process.alive?(ctx.pid)
    end
  end

  describe "WAL write-through" do
    test "appends the in-flight record at dispatch, before paying" do
      n = System.unique_integer([:positive])
      table = :"wal_wt_#{n}"
      pubsub = :"wal_wt_pubsub_#{n}"
      client_name = :"wal_wt_client_#{n}"
      wal_name = :"wal_wt_agent_#{n}"

      start_supervised!({Registry, keys: :duplicate, name: pubsub}, id: pubsub)
      start_supervised!({MockClient, name: client_name}, id: {MockClient, client_name})
      start_supervised!({MockWAL, name: wal_name}, id: wal_name)

      # Slow client — the dispatch-time record must exist while the
      # payment is still in flight.
      MockClient.set_response(client_name, :pay_invoice, fn ->
        Process.sleep(60_000)
        {:error, :timeout}
      end)

      pid =
        start_supervised!(
          {Executor,
           [
             client: {MockClient, client_name},
             pubsub: pubsub,
             table_name: table,
             max_concurrent: 10,
             wal: {MockWAL, wal_name},
             name: :"wal_wt_srv_#{n}"
           ]},
          id: {Executor, n}
        )

      payment = build_test_payment()
      assert :ok = Executor.submit(pid, payment)

      assert [record] = MockWAL.entries(wal_name)
      assert record.payment_hash == payment.payment_hash
      assert record.status == :in_flight
      assert record.attempt == 1
    end

    test "terminal resolution is appended (oldest first)" do
      n = System.unique_integer([:positive])
      table = :"wal_term_#{n}"
      pubsub = :"wal_term_pubsub_#{n}"
      client_name = :"wal_term_client_#{n}"
      wal_name = :"wal_term_agent_#{n}"

      start_supervised!({Registry, keys: :duplicate, name: pubsub}, id: pubsub)
      start_supervised!({MockClient, name: client_name}, id: {MockClient, client_name})
      start_supervised!({MockWAL, name: wal_name}, id: wal_name)

      preimage = :crypto.strong_rand_bytes(32)
      preimage_hex = Base.encode16(preimage, case: :lower)

      MockClient.set_response(
        client_name,
        :pay_invoice,
        {:ok, %{"preimage" => preimage_hex, "fees" => 1}}
      )

      pid =
        start_supervised!(
          {Executor,
           [
             client: {MockClient, client_name},
             pubsub: pubsub,
             table_name: table,
             max_concurrent: 10,
             wal: {MockWAL, wal_name},
             name: :"wal_term_srv_#{n}"
           ]},
          id: {Executor, n}
        )

      payment = build_test_payment()
      assert :ok = Executor.submit(pid, payment)

      FireBirdHelpers.await_condition(fn ->
        match?({:ok, %{status: :succeeded}}, Executor.lookup(table, payment.payment_hash))
      end)

      statuses = wal_name |> MockWAL.entries() |> Enum.map(& &1.status)
      assert statuses == [:in_flight, :succeeded]
    end

    test "submit refuses when the WAL is unavailable" do
      n = System.unique_integer([:positive])
      table = :"wal_down_#{n}"
      pubsub = :"wal_down_pubsub_#{n}"
      client_name = :"wal_down_client_#{n}"
      wal_name = :"wal_down_agent_#{n}"

      start_supervised!({Registry, keys: :duplicate, name: pubsub}, id: pubsub)
      start_supervised!({MockClient, name: client_name}, id: {MockClient, client_name})
      start_supervised!({MockWAL, name: wal_name}, id: wal_name)

      MockWAL.set_fail_appends(wal_name, true)

      pid =
        start_supervised!(
          {Executor,
           [
             client: {MockClient, client_name},
             pubsub: pubsub,
             table_name: table,
             max_concurrent: 10,
             wal: {MockWAL, wal_name},
             name: :"wal_down_srv_#{n}"
           ]},
          id: {Executor, n}
        )

      payment = build_test_payment()
      assert {:error, :wal_unavailable} = Executor.submit(pid, payment)
      assert {:error, :not_found} = Executor.lookup(table, payment.payment_hash)
      assert MockClient.calls(client_name, :pay_invoice) == []
    end

    test "recovery skips resolved payments, revives in-flight and retrying" do
      n = System.unique_integer([:positive])
      table = :"wal_rec_#{n}"
      pubsub = :"wal_rec_pubsub_#{n}"
      client_name = :"wal_rec_client_#{n}"
      wal_name = :"wal_rec_agent_#{n}"

      start_supervised!({Registry, keys: :duplicate, name: pubsub}, id: pubsub)
      start_supervised!({MockClient, name: client_name}, id: {MockClient, client_name})
      start_supervised!({MockWAL, name: wal_name}, id: wal_name)

      resolved = build_test_payment()
      MockWAL.append(wal_name, %{resolved | status: :in_flight, attempt: 1})
      MockWAL.append(wal_name, %{resolved | status: :succeeded, attempt: 1})

      wedged = build_test_payment()
      MockWAL.append(wal_name, %{wedged | status: :retrying, attempt: 1})

      already_unknown = build_test_payment()
      MockWAL.append(wal_name, %{already_unknown | status: :in_flight, attempt: 1})
      MockWAL.append(wal_name, %{already_unknown | status: :unknown, attempt: 1})

      start_supervised!(
        {Executor,
         [
           client: {MockClient, client_name},
           pubsub: pubsub,
           table_name: table,
           max_concurrent: 10,
           wal: {MockWAL, wal_name},
           name: :"wal_rec_srv_#{n}"
         ]},
        id: {Executor, n}
      )

      FireBirdHelpers.await_condition(fn ->
        match?({:ok, %{status: :unknown}}, Executor.lookup(table, wedged.payment_hash))
      end)

      assert {:error, :not_found} = Executor.lookup(table, resolved.payment_hash)
      assert {:ok, %{status: :unknown}} = Executor.lookup(table, wedged.payment_hash)
      assert {:error, :not_found} = Executor.lookup(table, already_unknown.payment_hash)
      assert MockClient.calls(client_name, :pay_invoice) == []
    end

    test "terminate persists :retrying payments" do
      n = System.unique_integer([:positive])
      table = :"wal_retry_#{n}"
      pubsub = :"wal_retry_pubsub_#{n}"
      client_name = :"wal_retry_client_#{n}"
      wal_name = :"wal_retry_agent_#{n}"

      start_supervised!({Registry, keys: :duplicate, name: pubsub}, id: pubsub)
      start_supervised!({MockClient, name: client_name}, id: {MockClient, client_name})
      start_supervised!({MockWAL, name: wal_name}, id: wal_name)

      MockClient.set_response(
        client_name,
        :pay_invoice,
        {:error, {:phoenixd_error, :route_not_found, "no route"}}
      )

      pid =
        start_supervised!(
          {Executor,
           [
             client: {MockClient, client_name},
             pubsub: pubsub,
             table_name: table,
             max_concurrent: 10,
             wal: {MockWAL, wal_name},
             name: :"wal_retry_srv_#{n}"
           ]},
          id: {Executor, n}
        )

      payment = build_test_payment()
      assert :ok = Executor.submit(pid, payment)

      FireBirdHelpers.await_condition(fn ->
        match?({:ok, %{status: :retrying}}, Executor.lookup(table, payment.payment_hash))
      end)

      GenServer.stop(pid, :normal)

      last = wal_name |> MockWAL.entries() |> List.last()
      assert last.payment_hash == payment.payment_hash
      assert last.status == :retrying
    end
  end

  describe "ambiguous success responses" do
    test "success response without a preimage marks the payment :unknown" do
      n = System.unique_integer([:positive])
      table = :"ambig_#{n}"
      pubsub = :"ambig_pubsub_#{n}"
      client_name = :"ambig_client_#{n}"

      start_supervised!({Registry, keys: :duplicate, name: pubsub}, id: pubsub)
      start_supervised!({MockClient, name: client_name}, id: {MockClient, client_name})

      MockClient.set_response(client_name, :pay_invoice, {:ok, %{"paymentId" => "phx_1"}})

      pid =
        start_supervised!(
          {Executor,
           [
             client: {MockClient, client_name},
             pubsub: pubsub,
             table_name: table,
             max_concurrent: 10,
             name: :"ambig_srv_#{n}"
           ]},
          id: {Executor, n}
        )

      Registry.register(pubsub, :payment, [])

      payment = build_test_payment()
      assert :ok = Executor.submit(pid, payment)

      FireBirdHelpers.await_condition(fn ->
        match?({:ok, %{status: :unknown}}, Executor.lookup(table, payment.payment_hash))
      end)

      assert_receive {FireBird.PubSub, :payment, %FireBird.Events.PaymentUnknown{payment_hash: ph}}
                     when ph == payment.payment_hash
    end

    test "non-map success response marks the payment :unknown" do
      n = System.unique_integer([:positive])
      table = :"ambig2_#{n}"
      pubsub = :"ambig2_pubsub_#{n}"
      client_name = :"ambig2_client_#{n}"

      start_supervised!({Registry, keys: :duplicate, name: pubsub}, id: pubsub)
      start_supervised!({MockClient, name: client_name}, id: {MockClient, client_name})

      MockClient.set_response(client_name, :pay_invoice, {:ok, "garbage"})

      pid =
        start_supervised!(
          {Executor,
           [
             client: {MockClient, client_name},
             pubsub: pubsub,
             table_name: table,
             max_concurrent: 10,
             name: :"ambig2_srv_#{n}"
           ]},
          id: {Executor, n}
        )

      payment = build_test_payment()
      assert :ok = Executor.submit(pid, payment)

      FireBirdHelpers.await_condition(fn ->
        match?({:ok, %{status: :unknown}}, Executor.lookup(table, payment.payment_hash))
      end)
    end
  end

  describe "terminal cleanup of failed payments" do
    test "cleans up definitively-failed payments after retention period" do
      n = System.unique_integer([:positive])
      table = :"pay_failed_cleanup_#{n}"
      pubsub = :"pay_failed_cleanup_pubsub_#{n}"
      client_name = :"pay_failed_cleanup_client_#{n}"

      start_supervised!({Registry, keys: :duplicate, name: pubsub}, id: pubsub)
      start_supervised!({MockClient, name: client_name}, id: {MockClient, n})

      MockClient.set_response(
        client_name,
        :pay_invoice,
        {:error, {:http_error, 400, "bad invoice"}}
      )

      # 4xx outcomes are confirmed against the node before release:
      # a 404 on the lookup means no payment record — definitive.
      MockClient.set_response(
        client_name,
        :get_outgoing_payment_by_hash,
        {:error, {:http_error, 404, "not found"}}
      )

      pid =
        start_supervised!(
          {Executor,
           [
             client: {MockClient, client_name},
             pubsub: pubsub,
             table_name: table,
             max_concurrent: 10,
             retention_ms: 1,
             cleanup_interval: 600_000,
             name: :"pay_failed_cleanup_#{n}"
           ]},
          id: {Executor, n}
        )

      payment = build_test_payment()
      Executor.submit(pid, payment)

      FireBirdHelpers.await_condition(fn ->
        match?({:ok, %{status: :failed}}, Executor.lookup(table, payment.payment_hash))
      end)

      Process.sleep(10)
      send(pid, :cleanup)
      :sys.get_state(pid)

      assert {:error, :not_found} = Executor.lookup(table, payment.payment_hash)
    end
  end

  describe "push payments — :offer destination" do
    test "dispatches to pay_offer and stores in ETS as succeeded", ctx do
      payment = build_offer_payment()
      preimage = :crypto.strong_rand_bytes(32)
      preimage_hex = Base.encode16(preimage, case: :lower)

      MockClient.set_response(
        ctx.client,
        :pay_offer,
        {:ok, %{"preimage" => preimage_hex, "fees" => 10}}
      )

      assert :ok = Executor.submit(ctx.pid, payment)

      FireBirdHelpers.await_condition(fn ->
        match?(
          {:ok, %{status: :succeeded}},
          Executor.lookup(ctx.table, payment.payment_hash)
        )
      end)

      # Recorded call arrives with the offer string as the first arg,
      # not a bolt11 — this is the destination-dispatch invariant.
      calls = MockClient.calls(ctx.client, :pay_offer)
      assert length(calls) == 1
      {offer, amount, _desc, _fee_cap} = hd(calls)
      assert offer == payment.destination
      assert amount == payment.amount_sats
    end

    test "publishes PaymentUnknown on offer HTTP timeout — never auto-retries", ctx do
      payment = build_offer_payment()

      Registry.register(ctx.pubsub, :payment, [])

      MockClient.set_response(ctx.client, :pay_offer, {:error, :timeout})

      Executor.submit(ctx.pid, payment)

      assert_receive {FireBird.PubSub, :payment, %FireBird.Events.PaymentUnknown{}}, 1_000
      refute_receive {FireBird.PubSub, :payment, %FireBird.Events.PaymentFailed{}}, 100
      refute_receive {FireBird.PubSub, :payment, %FireBird.Events.PaymentExhausted{}}, 100
    end

    test "does NOT accept pay_offer paths through the pay_invoice client stub", ctx do
      payment = build_offer_payment()
      MockClient.set_response(ctx.client, :pay_invoice, {:error, :should_not_be_called})

      MockClient.set_response(
        ctx.client,
        :pay_offer,
        {:ok,
         %{"preimage" => Base.encode16(:crypto.strong_rand_bytes(32), case: :lower), "fees" => 0}}
      )

      assert :ok = Executor.submit(ctx.pid, payment)

      FireBirdHelpers.await_condition(fn ->
        match?({:ok, %{status: :succeeded}}, Executor.lookup(ctx.table, payment.payment_hash))
      end)

      # pay_invoice must not have been called for this :offer submission
      assert MockClient.calls(ctx.client, :pay_invoice) == []
    end
  end

  defp build_test_payment(opts \\ []) do
    payment_hash = Keyword.get_lazy(opts, :payment_hash, fn -> :crypto.strong_rand_bytes(32) end)

    Payment.new(
      payment_hash: payment_hash,
      bolt11: "lnbc1000u1ptest#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}",
      amount_sats: Keyword.get(opts, :amount_sats, 1_000),
      created_at: DateTime.utc_now(),
      max_attempts: Keyword.get(opts, :max_attempts, 3)
    )
  end

  defp build_offer_payment(opts \\ []) do
    payment_hash = Keyword.get_lazy(opts, :payment_hash, fn -> :crypto.strong_rand_bytes(32) end)

    offer =
      Keyword.get(
        opts,
        :offer,
        "lno1test#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"
      )

    Payment.new(
      payment_hash: payment_hash,
      amount_sats: Keyword.get(opts, :amount_sats, 1_000),
      created_at: DateTime.utc_now(),
      destination_type: :offer,
      destination: offer,
      max_attempts: Keyword.get(opts, :max_attempts, 3)
    )
  end
end
