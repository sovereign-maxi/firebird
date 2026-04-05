defmodule FireBird.WebhookTest do
  use ExUnit.Case, async: false

  alias FireBird.Webhook

  @secret "test-webhook-secret"

  setup do
    n = System.unique_integer([:positive])
    dedup_table = :"webhook_dedup_test_#{n}"
    rate_limit_table = :"webhook_rate_limit_test_#{n}"

    opts =
      Webhook.init(
        webhook_secret: @secret,
        invoice_manager: :unused,
        dedup_table: dedup_table,
        rate_limit_table: rate_limit_table
      )

    %{opts: opts, dedup_table: dedup_table, rate_limit_table: rate_limit_table}
  end

  describe "POST /payment-received" do
    test "valid signature and new hash returns 200", %{opts: opts} do
      payload = Jason.encode!(%{"paymentHash" => random_hex()})
      signature = compute_signature(payload, @secret)

      conn =
        :post
        |> Plug.Test.conn("/payment-received", payload)
        |> Plug.Conn.put_req_header("x-phoenix-signature", signature)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Webhook.call(opts)

      assert conn.status == 200
      assert conn.resp_body == "ok"
    end

    test "invalid signature returns 401", %{opts: opts} do
      payload = Jason.encode!(%{"paymentHash" => random_hex()})

      conn =
        :post
        |> Plug.Test.conn("/payment-received", payload)
        |> Plug.Conn.put_req_header("x-phoenix-signature", "bad-sig")
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Webhook.call(opts)

      assert conn.status == 401
      assert conn.resp_body == "invalid signature"
    end

    test "duplicate hash returns 200 already processed", %{opts: opts} do
      hash = random_hex()
      payload = Jason.encode!(%{"paymentHash" => hash})
      signature = compute_signature(payload, @secret)

      build_conn = fn ->
        :post
        |> Plug.Test.conn("/payment-received", payload)
        |> Plug.Conn.put_req_header("x-phoenix-signature", signature)
        |> Plug.Conn.put_req_header("content-type", "application/json")
      end

      # First call
      conn1 = Webhook.call(build_conn.(), opts)
      assert conn1.status == 200
      assert conn1.resp_body == "ok"

      # Duplicate
      conn2 = Webhook.call(build_conn.(), opts)
      assert conn2.status == 200
      assert conn2.resp_body == "already processed"
    end

    test "missing signature header returns 401", %{opts: opts} do
      payload = Jason.encode!(%{"paymentHash" => random_hex()})

      conn =
        :post
        |> Plug.Test.conn("/payment-received", payload)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Webhook.call(opts)

      assert conn.status == 401
    end

    test "invalid JSON with valid signature returns 400", %{opts: opts} do
      payload = "not json"
      signature = compute_signature(payload, @secret)

      conn =
        :post
        |> Plug.Test.conn("/payment-received", payload)
        |> Plug.Conn.put_req_header("x-phoenix-signature", signature)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Webhook.call(opts)

      assert conn.status == 400
    end
  end

  describe "rate limiting" do
    test "allows requests under the limit", %{opts: opts} do
      # Default limit is 100, this should pass
      payload = Jason.encode!(%{"paymentHash" => random_hex()})
      signature = compute_signature(payload, @secret)

      conn =
        :post
        |> Plug.Test.conn("/payment-received", payload)
        |> Plug.Conn.put_req_header("x-phoenix-signature", signature)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Webhook.call(opts)

      assert conn.status == 200
    end

    test "returns 429 when rate limit exceeded" do
      n = System.unique_integer([:positive])
      dedup_table = :"webhook_dedup_rl_#{n}"
      rate_limit_table = :"webhook_rate_limit_rl_#{n}"

      opts =
        Webhook.init(
          webhook_secret: @secret,
          invoice_manager: :unused,
          dedup_table: dedup_table,
          rate_limit_table: rate_limit_table,
          rate_limit_max: 2,
          rate_limit_window_ms: 60_000
        )

      make_request = fn ->
        payload = Jason.encode!(%{"paymentHash" => random_hex()})
        signature = compute_signature(payload, @secret)

        :post
        |> Plug.Test.conn("/payment-received", payload)
        |> Plug.Conn.put_req_header("x-phoenix-signature", signature)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Webhook.call(opts)
      end

      # First two should succeed
      assert make_request.().status == 200
      assert make_request.().status == 200

      # Third should be rate limited
      conn = make_request.()
      assert conn.status == 429
      assert conn.resp_body == "rate limit exceeded"
    end

    test "resets after window expires" do
      n = System.unique_integer([:positive])
      dedup_table = :"webhook_dedup_rl2_#{n}"
      rate_limit_table = :"webhook_rate_limit_rl2_#{n}"

      opts =
        Webhook.init(
          webhook_secret: @secret,
          invoice_manager: :unused,
          dedup_table: dedup_table,
          rate_limit_table: rate_limit_table,
          rate_limit_max: 1,
          rate_limit_window_ms: 1
        )

      make_request = fn ->
        payload = Jason.encode!(%{"paymentHash" => random_hex()})
        signature = compute_signature(payload, @secret)

        :post
        |> Plug.Test.conn("/payment-received", payload)
        |> Plug.Conn.put_req_header("x-phoenix-signature", signature)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Webhook.call(opts)
      end

      # First request succeeds
      assert make_request.().status == 200

      # Wait for window to expire
      Process.sleep(5)

      # Should succeed again after window reset
      assert make_request.().status == 200
    end
  end

  describe "webhook triggers InvoiceManager.check_payment" do
    test "valid webhook with paymentHash triggers check_payment" do
      n = System.unique_integer([:positive])
      dedup_table = :"webhook_inv_dedup_#{n}"
      rate_limit_table = :"webhook_inv_rl_#{n}"
      inv_table = :"webhook_inv_table_#{n}"
      pubsub = :"webhook_inv_pubsub_#{n}"
      client_name = :"webhook_inv_client_#{n}"

      start_supervised!({Registry, keys: :duplicate, name: pubsub}, id: pubsub)
      start_supervised!({FireBird.MockClient, name: client_name}, id: client_name)

      pid =
        start_supervised!(
          {FireBird.Manager,
           [
             client: {FireBird.MockClient, client_name},
             pubsub: pubsub,
             table_name: inv_table,
             poll_interval: 600_000,
             name: :"webhook_inv_mgr_#{n}"
           ]},
          id: {FireBird.Manager, n}
        )

      # Track a pending invoice
      preimage = :crypto.strong_rand_bytes(32)
      payment_hash = :crypto.hash(:sha256, preimage)
      preimage_hex = Base.encode16(preimage, case: :lower)
      payment_hash_hex = Base.encode16(payment_hash, case: :lower)

      invoice =
        FireBird.Invoice.new(
          payment_hash: payment_hash,
          bolt11: "lnbc1000u1ptest#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}",
          amount_sats: 1_000,
          created_at: DateTime.utc_now(),
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        )

      FireBird.Manager.track(pid, invoice)

      FireBird.MockClient.set_response(
        client_name,
        :get_incoming_payment,
        {:ok, %{"isPaid" => true, "preimage" => preimage_hex}}
      )

      Registry.register(pubsub, :invoice, [])

      opts =
        Webhook.init(
          webhook_secret: @secret,
          invoice_manager: pid,
          dedup_table: dedup_table,
          rate_limit_table: rate_limit_table
        )

      payload = Jason.encode!(%{"paymentHash" => payment_hash_hex})
      signature = compute_signature(payload, @secret)

      conn =
        :post
        |> Plug.Test.conn("/payment-received", payload)
        |> Plug.Conn.put_req_header("x-phoenix-signature", signature)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Webhook.call(opts)

      assert conn.status == 200

      # Wait for the async cast to be processed
      :sys.get_state(pid)

      assert_receive {FireBird.PubSub, :invoice,
                      %FireBird.Events.InvoicePaid{payment_hash: ^payment_hash}}

      assert {:ok, updated} = FireBird.Manager.lookup(inv_table, payment_hash)
      assert updated.status == :paid
    end
  end

  describe "body size limit" do
    test "rejects oversized body with 400", %{opts: opts} do
      # Create a payload larger than 10KB
      large_value = String.duplicate("A", 11_000)
      payload = Jason.encode!(%{"paymentHash" => large_value})
      signature = compute_signature(payload, @secret)

      conn =
        :post
        |> Plug.Test.conn("/payment-received", payload)
        |> Plug.Conn.put_req_header("x-phoenix-signature", signature)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Webhook.call(opts)

      assert conn.status == 400
    end
  end

  describe "config validation" do
    test "rejects empty webhook_secret" do
      assert_raise ArgumentError, ~r/webhook_secret must be a non-empty binary/, fn ->
        Webhook.init(
          webhook_secret: "",
          invoice_manager: :unused,
          dedup_table: :"wh_val_dedup_#{System.unique_integer([:positive])}",
          rate_limit_table: :"wh_val_rl_#{System.unique_integer([:positive])}"
        )
      end
    end

    test "rejects non-binary webhook_secret" do
      assert_raise ArgumentError, ~r/webhook_secret must be a non-empty binary/, fn ->
        Webhook.init(
          webhook_secret: nil,
          invoice_manager: :unused,
          dedup_table: :"wh_val2_dedup_#{System.unique_integer([:positive])}",
          rate_limit_table: :"wh_val2_rl_#{System.unique_integer([:positive])}"
        )
      end
    end
  end

  describe "ETS resilience" do
    test "recovers from deleted rate_limit table", %{opts: opts, rate_limit_table: rate_limit_table} do
      :ets.delete(rate_limit_table)

      payload = Jason.encode!(%{"paymentHash" => random_hex()})
      signature = compute_signature(payload, @secret)

      conn =
        :post
        |> Plug.Test.conn("/payment-received", payload)
        |> Plug.Conn.put_req_header("x-phoenix-signature", signature)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Webhook.call(opts)

      assert conn.status == 200
      assert :ets.whereis(rate_limit_table) != :undefined
    end

    test "recovers from deleted dedup table", %{opts: opts, dedup_table: dedup_table} do
      :ets.delete(dedup_table)

      payload = Jason.encode!(%{"paymentHash" => random_hex()})
      signature = compute_signature(payload, @secret)

      conn =
        :post
        |> Plug.Test.conn("/payment-received", payload)
        |> Plug.Conn.put_req_header("x-phoenix-signature", signature)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Webhook.call(opts)

      assert conn.status == 200
      assert :ets.whereis(dedup_table) != :undefined
    end
  end

  describe "unknown route" do
    test "returns 404", %{opts: opts} do
      conn =
        :get
        |> Plug.Test.conn("/unknown")
        |> Webhook.call(opts)

      assert conn.status == 404
    end
  end

  defp compute_signature(body, secret) do
    Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)
  end

  defp random_hex do
    Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
  end
end
