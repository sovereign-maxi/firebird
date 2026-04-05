defmodule FireBird.HTTPTest do
  use ExUnit.Case, async: true

  alias FireBird.HTTP

  describe "new/1" do
    test "creates a config struct with required fields" do
      config = HTTP.new(base_url: "http://localhost:9740", password: "secret", finch_name: :test)

      assert config.base_url == "http://localhost:9740"
      assert config.password == "secret"
      assert config.finch_name == :test
    end

    test "sets default receive_timeout" do
      config = HTTP.new(base_url: "https://node.example.com", password: "pw", finch_name: :test)
      assert config.receive_timeout == 30_000
    end

    test "allows custom receive_timeout" do
      config =
        HTTP.new(
          base_url: "https://node.example.com",
          password: "pw",
          finch_name: :test,
          receive_timeout: 60_000
        )

      assert config.receive_timeout == 60_000
    end

    test "accepts https URLs" do
      config = HTTP.new(base_url: "https://node.example.com", password: "pw", finch_name: :test)
      assert config.base_url == "https://node.example.com"
    end

    test "rejects non-HTTP URLs" do
      assert_raise ArgumentError, ~r/invalid base_url/, fn ->
        HTTP.new(base_url: "ftp://localhost", password: "pw", finch_name: :test)
      end
    end

    test "rejects URLs without a host" do
      assert_raise ArgumentError, ~r/invalid base_url/, fn ->
        HTTP.new(base_url: "http://", password: "pw", finch_name: :test)
      end
    end

    test "rejects empty string URL" do
      assert_raise ArgumentError, ~r/invalid base_url/, fn ->
        HTTP.new(base_url: "", password: "pw", finch_name: :test)
      end
    end

    test "raises on missing required fields" do
      assert_raise ArgumentError, fn ->
        HTTP.new(base_url: "http://localhost:9740")
      end
    end

    test "logs warning for plaintext HTTP URL" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          HTTP.new(base_url: "http://localhost:9740", password: "pw", finch_name: :test)
        end)

      assert log =~ "plaintext HTTP"
      assert log =~ "Use https:// in production"
    end

    test "does not log warning for HTTPS URL" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          HTTP.new(base_url: "https://node.example.com", password: "pw", finch_name: :test)
        end)

      refute log =~ "plaintext HTTP"
    end
  end

  describe "Inspect protocol" do
    test "redacts password" do
      config =
        HTTP.new(base_url: "https://node.example.com", password: "supersecret", finch_name: :test)

      inspected = inspect(config)

      assert inspected =~ "**REDACTED**"
      refute inspected =~ "supersecret"
    end
  end

  describe "API methods" do
    setup do
      bypass = Bypass.open()
      finch_name = :"finch_http_test_#{System.unique_integer([:positive])}"
      start_supervised!({Finch, name: finch_name})

      {config, _log} =
        ExUnit.CaptureLog.with_log(fn ->
          HTTP.new(
            base_url: "http://localhost:#{bypass.port}",
            password: "test_pass",
            finch_name: finch_name
          )
        end)

      %{bypass: bypass, config: config}
    end

    test "create_invoice/3 sends POST with form body and auth header",
         %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "POST", "/createinvoice", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)
        assert params["amountSat"] == "1000"
        assert params["description"] == "test invoice"

        [auth] = Plug.Conn.get_req_header(conn, "authorization")
        assert auth == "Basic " <> Base.encode64(":test_pass")

        Plug.Conn.resp(conn, 200, Jason.encode!(%{"paymentHash" => "abc", "serialized" => "lnbc"}))
      end)

      assert {:ok, %{"paymentHash" => "abc"}} = HTTP.create_invoice(config, 1000, "test invoice")
    end

    test "create_invoice/3 preserves non-ASCII Unicode in descriptions",
         %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "POST", "/createinvoice", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)
        assert params["description"] =~ "café"
        assert params["description"] =~ "日本語"

        Plug.Conn.resp(conn, 200, Jason.encode!(%{"paymentHash" => "abc"}))
      end)

      assert {:ok, _resp} = HTTP.create_invoice(config, 1000, "café 日本語")
    end

    test "create_invoice/3 sanitizes long descriptions",
         %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "POST", "/createinvoice", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)
        assert String.length(params["description"]) <= 639

        Plug.Conn.resp(conn, 200, Jason.encode!(%{"paymentHash" => "abc"}))
      end)

      long_desc = String.duplicate("a", 700)
      assert {:ok, _resp} = HTTP.create_invoice(config, 1000, long_desc)
    end

    test "pay_invoice/4 sends POST with invoice and amount",
         %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "POST", "/payinvoice", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)
        assert params["invoice"] == "lnbc100n1..."
        assert params["amountSat"] == "500"
        assert params["description"] == "payment"

        Plug.Conn.resp(conn, 200, Jason.encode!(%{"preimage" => "aa", "fees" => 1}))
      end)

      assert {:ok, %{"preimage" => "aa"}} =
               HTTP.pay_invoice(config, "lnbc100n1...", 500, "payment")
    end

    test "get_balance/1 sends GET to /getbalance", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "GET", "/getbalance", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"balanceSat" => 50_000}))
      end)

      assert {:ok, %{"balanceSat" => 50_000}} = HTTP.get_balance(config)
    end

    test "get_incoming_payment/2 hex-encodes the payment hash",
         %{bypass: bypass, config: config} do
      hash = :crypto.strong_rand_bytes(32)
      hex = Base.encode16(hash, case: :lower)

      Bypass.expect_once(bypass, "GET", "/payments/incoming/#{hex}", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"preimage" => "bb"}))
      end)

      assert {:ok, %{"preimage" => "bb"}} = HTTP.get_incoming_payment(config, hash)
    end

    test "get_info/1 sends GET to /getinfo", %{bypass: bypass, config: config} do
      info = %{"nodeId" => "abc", "balanceSat" => 142_780, "channels" => []}

      Bypass.expect_once(bypass, "GET", "/getinfo", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(info))
      end)

      assert {:ok, ^info} = HTTP.get_info(config)
    end

    test "health_check/1 returns :ok on success", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "GET", "/getinfo", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"nodeId" => "abc"}))
      end)

      assert :ok = HTTP.health_check(config)
    end

    test "health_check/1 returns error on non-2xx", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "GET", "/getinfo", fn conn ->
        Plug.Conn.resp(conn, 500, "internal error")
      end)

      assert {:error, {:http_error, 500, "internal error"}} = HTTP.health_check(config)
    end

    test "returns HTTP error tuple for non-2xx responses",
         %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "GET", "/getbalance", fn conn ->
        Plug.Conn.resp(conn, 403, "forbidden")
      end)

      assert {:error, {:http_error, 403, "forbidden"}} = HTTP.get_balance(config)
    end

    test "returns error on connection failure", %{bypass: bypass, config: config} do
      Bypass.down(bypass)
      assert {:error, _reason} = HTTP.get_balance(config)
    end

    test "returns decode_error for invalid JSON in 2xx response",
         %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "GET", "/getbalance", fn conn ->
        Plug.Conn.resp(conn, 200, "not valid json")
      end)

      assert {:error, {:decode_error, %Jason.DecodeError{}}} = HTTP.get_balance(config)
    end
  end

  describe "concurrent requests" do
    setup do
      bypass = Bypass.open()
      finch_name = :"finch_concurrent_test_#{System.unique_integer([:positive])}"
      start_supervised!({Finch, name: finch_name})

      {config, _log} =
        ExUnit.CaptureLog.with_log(fn ->
          HTTP.new(
            base_url: "http://localhost:#{bypass.port}",
            password: "test_pass",
            finch_name: finch_name
          )
        end)

      %{bypass: bypass, config: config}
    end

    test "handles multiple concurrent create_invoice requests",
         %{bypass: bypass, config: config} do
      Bypass.expect(bypass, "POST", "/createinvoice", fn conn ->
        # Simulate a small delay per request
        Process.sleep(10)
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(body)
        amount = params["amountSat"]

        Plug.Conn.resp(
          conn,
          200,
          Jason.encode!(%{"paymentHash" => "hash_#{amount}", "serialized" => "lnbc"})
        )
      end)

      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            HTTP.create_invoice(config, i * 100, "invoice #{i}")
          end)
        end

      results = Task.await_many(tasks, 5_000)

      assert length(results) == 10
      assert Enum.all?(results, &match?({:ok, %{"paymentHash" => _}}, &1))
    end

    test "handles mixed concurrent GET and POST requests",
         %{bypass: bypass, config: config} do
      Bypass.expect(bypass, fn conn ->
        Process.sleep(5)

        case conn.request_path do
          "/getbalance" ->
            Plug.Conn.resp(conn, 200, Jason.encode!(%{"balanceSat" => 50_000}))

          "/createinvoice" ->
            Plug.Conn.resp(conn, 200, Jason.encode!(%{"paymentHash" => "abc"}))

          "/getinfo" ->
            Plug.Conn.resp(conn, 200, Jason.encode!(%{"nodeId" => "node1"}))

          _other ->
            Plug.Conn.resp(conn, 404, "not found")
        end
      end)

      tasks = [
        Task.async(fn -> HTTP.get_balance(config) end),
        Task.async(fn -> HTTP.create_invoice(config, 1000, "test") end),
        Task.async(fn -> HTTP.health_check(config) end),
        Task.async(fn -> HTTP.get_balance(config) end),
        Task.async(fn -> HTTP.create_invoice(config, 2000, "test2") end)
      ]

      results = Task.await_many(tasks, 5_000)

      assert {:ok, %{"balanceSat" => 50_000}} = Enum.at(results, 0)
      assert {:ok, %{"paymentHash" => "abc"}} = Enum.at(results, 1)
      assert :ok = Enum.at(results, 2)
      assert {:ok, %{"balanceSat" => 50_000}} = Enum.at(results, 3)
      assert {:ok, %{"paymentHash" => "abc"}} = Enum.at(results, 4)
    end

    test "concurrent requests with partial failures",
         %{bypass: bypass, config: config} do
      counter = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "GET", "/getbalance", fn conn ->
        count = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)

        if rem(count, 2) == 0 do
          Plug.Conn.resp(conn, 200, Jason.encode!(%{"balanceSat" => 50_000}))
        else
          Plug.Conn.resp(conn, 500, "internal error")
        end
      end)

      tasks =
        for _i <- 1..6 do
          Task.async(fn -> HTTP.get_balance(config) end)
        end

      results = Task.await_many(tasks, 5_000)

      successes = Enum.count(results, &match?({:ok, _val}, &1))
      failures = Enum.count(results, &match?({:error, _reason}, &1))

      assert successes > 0
      assert failures > 0
      assert successes + failures == 6
    end
  end
end
