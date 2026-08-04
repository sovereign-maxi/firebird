defmodule FireBird.ExecutorTest do
  use ExUnit.Case, async: false

  alias FireBird.Executor
  alias FireBird.MockClient
  alias FireBird.MockWAL
  alias FireBird.Payment

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

    test "4xx client error publishes PaymentExhausted (definitive failure)", ctx do
      Registry.register(ctx.pubsub, :payment, [])
      payment = build_test_payment(max_attempts: 3)

      MockClient.set_response(ctx.client, :pay_invoice, {:error, {:http_error, 400, "Bad Request"}})

      Executor.submit(ctx.pid, payment)

      # Definitive-failure release path — one Exhausted event, no
      # Failed/retry ladder.
      assert_receive {FireBird.PubSub, :payment, %FireBird.Events.PaymentExhausted{}}, 1_000
      refute_receive {FireBird.PubSub, :payment, %FireBird.Events.PaymentFailed{}}, 200
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
    test "recovers in-flight payments from WAL on init" do
      n = System.unique_integer([:positive])
      table = :"pay_recover_#{n}"
      pubsub = :"pay_recover_pubsub_#{n}"
      client_name = :"pay_recover_client_#{n}"
      wal_name = :"pay_recover_wal_#{n}"

      start_supervised!({Registry, keys: :duplicate, name: pubsub}, id: pubsub)
      start_supervised!({MockClient, name: client_name}, id: {MockClient, client_name})
      start_supervised!({MockWAL, name: wal_name}, id: wal_name)

      # Pre-populate WAL with an in-flight payment
      payment = build_test_payment(max_attempts: 3)
      in_flight = %{payment | status: :in_flight, attempt: 1}
      MockWAL.append(wal_name, in_flight)

      preimage = :crypto.strong_rand_bytes(32)
      preimage_hex = Base.encode16(preimage, case: :lower)

      MockClient.set_response(
        client_name,
        :pay_invoice,
        {:ok, %{"preimage" => preimage_hex, "fees" => 0}}
      )

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

      # Poll until recovered payment appears in ETS
      FireBirdHelpers.await_condition(fn ->
        match?({:ok, _}, Executor.lookup(table, payment.payment_hash))
      end)

      assert {:ok, found} = Executor.lookup(table, payment.payment_hash)
      assert found.status in [:retrying, :in_flight, :succeeded]

      # Wait for retry to succeed
      assert_receive {FireBird.PubSub, :payment, %FireBird.Events.PaymentSent{}}, 5_000

      assert {:ok, result} = Executor.lookup(table, payment.payment_hash)
      assert result.status == :succeeded

      stop_supervised!({Executor, n})
      assert Process.alive?(pid) == false
    end

    test "marks max-attempt payments as exhausted on recovery" do
      n = System.unique_integer([:positive])
      table = :"pay_exhaust_#{n}"
      pubsub = :"pay_exhaust_pubsub_#{n}"
      client_name = :"pay_exhaust_client_#{n}"
      wal_name = :"pay_exhaust_wal_#{n}"

      start_supervised!({Registry, keys: :duplicate, name: pubsub}, id: pubsub)
      start_supervised!({MockClient, name: client_name}, id: {MockClient, client_name})
      start_supervised!({MockWAL, name: wal_name}, id: wal_name)

      # Pre-populate WAL with a payment at max attempts
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

      # Poll until recovery marks payment as exhausted
      FireBirdHelpers.await_condition(fn ->
        match?({:ok, %{status: :exhausted}}, Executor.lookup(table, payment.payment_hash))
      end)

      assert {:ok, result} = Executor.lookup(table, payment.payment_hash)
      assert result.status == :exhausted
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
end
