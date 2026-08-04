defmodule FireBird.MonitorTest do
  use ExUnit.Case, async: false

  alias FireBird.MockClient
  alias FireBird.Monitor

  @moduletag :scenario

  setup do
    n = System.unique_integer([:positive])
    table = :"liq_mon_test_#{n}"
    pubsub = :"liq_mon_pubsub_#{n}"
    client_name = :"liq_mon_client_#{n}"

    start_supervised!({Registry, keys: :duplicate, name: pubsub})
    start_supervised!({MockClient, name: client_name}, id: client_name)

    pid =
      start_supervised!(
        {Monitor,
         [
           client: {MockClient, client_name},
           pubsub: pubsub,
           table_name: table,
           poll_interval: 600_000,
           high_watermark: 1_000_000,
           low_watermark: 100_000,
           critical_watermark: 10_000,
           name: :"liq_mon_#{n}"
         ]}
      )

    %{pid: pid, table: table, pubsub: pubsub, client: client_name}
  end

  describe "init/1" do
    test "creates ETS table", %{table: table} do
      assert :ets.whereis(table) != :undefined
    end
  end

  describe "get_balance/1" do
    test "returns :not_found initially", %{table: table} do
      assert {:error, :not_found} = Monitor.get_balance(table)
    end

    test "returns value after poll", ctx do
      MockClient.set_response(ctx.client, :get_info, {:ok, %{"balanceSat" => 500_000}})
      send(ctx.pid, :poll)
      :sys.get_state(ctx.pid)

      assert {:ok, 500_000} = Monitor.get_balance(ctx.table)
    end
  end

  describe "poll" do
    test "stores balance in ETS", ctx do
      MockClient.set_response(ctx.client, :get_info, {:ok, %{"balanceSat" => 750_000}})
      send(ctx.pid, :poll)
      :sys.get_state(ctx.pid)

      assert {:ok, 750_000} = Monitor.get_balance(ctx.table)
    end

    test "normal→low publishes LiquidityLow", ctx do
      Registry.register(ctx.pubsub, :liquidity, [])
      MockClient.set_response(ctx.client, :get_info, {:ok, %{"balanceSat" => 50_000}})

      send(ctx.pid, :poll)
      :sys.get_state(ctx.pid)

      assert_receive {FireBird.PubSub, :liquidity,
                      %FireBird.Events.LiquidityLow{
                        balance_sats: 50_000
                      }}
    end

    test "normal→critical publishes LiquidityCritical", ctx do
      Registry.register(ctx.pubsub, :liquidity, [])
      MockClient.set_response(ctx.client, :get_info, {:ok, %{"balanceSat" => 5_000}})

      send(ctx.pid, :poll)
      :sys.get_state(ctx.pid)

      assert_receive {FireBird.PubSub, :liquidity,
                      %FireBird.Events.LiquidityCritical{
                        balance_sats: 5_000
                      }}
    end

    test "critical→normal publishes LiquidityRecovered", ctx do
      # First transition to critical
      MockClient.set_response(ctx.client, :get_info, {:ok, %{"balanceSat" => 5_000}})
      send(ctx.pid, :poll)
      :sys.get_state(ctx.pid)

      # Subscribe after first transition to only receive recovery
      Registry.register(ctx.pubsub, :liquidity, [])

      MockClient.set_response(ctx.client, :get_info, {:ok, %{"balanceSat" => 2_000_000}})
      send(ctx.pid, :poll)
      :sys.get_state(ctx.pid)

      assert_receive {FireBird.PubSub, :liquidity,
                      %FireBird.Events.LiquidityRecovered{
                        balance_sats: 2_000_000
                      }}
    end

    test "low→critical publishes LiquidityCritical", ctx do
      # First transition to low
      MockClient.set_response(ctx.client, :get_info, {:ok, %{"balanceSat" => 50_000}})
      send(ctx.pid, :poll)
      :sys.get_state(ctx.pid)

      Registry.register(ctx.pubsub, :liquidity, [])

      MockClient.set_response(ctx.client, :get_info, {:ok, %{"balanceSat" => 5_000}})
      send(ctx.pid, :poll)
      :sys.get_state(ctx.pid)

      assert_receive {FireBird.PubSub, :liquidity,
                      %FireBird.Events.LiquidityCritical{
                        balance_sats: 5_000
                      }}
    end

    test "critical→low publishes LiquidityLow when balance rises above critical", ctx do
      # First transition to critical
      MockClient.set_response(ctx.client, :get_info, {:ok, %{"balanceSat" => 5_000}})
      send(ctx.pid, :poll)
      :sys.get_state(ctx.pid)

      Registry.register(ctx.pubsub, :liquidity, [])

      # Balance rises above critical (10_000) but stays below low (100_000)
      MockClient.set_response(ctx.client, :get_info, {:ok, %{"balanceSat" => 50_000}})
      send(ctx.pid, :poll)
      :sys.get_state(ctx.pid)

      assert_receive {FireBird.PubSub, :liquidity,
                      %FireBird.Events.LiquidityLow{
                        balance_sats: 50_000
                      }}
    end

    test "same state emits no event", ctx do
      Registry.register(ctx.pubsub, :liquidity, [])

      # Balance in normal range, state is already :normal
      MockClient.set_response(ctx.client, :get_info, {:ok, %{"balanceSat" => 2_000_000}})
      send(ctx.pid, :poll)
      :sys.get_state(ctx.pid)

      refute_receive {FireBird.PubSub, :liquidity, _}
    end

    test "poll error does not crash GenServer", ctx do
      MockClient.set_response(ctx.client, :get_info, {:error, :connection_refused})
      send(ctx.pid, :poll)
      :sys.get_state(ctx.pid)

      assert Process.alive?(ctx.pid)
    end
  end

  describe "ensure_integer robustness" do
    test "handles string balance from API", ctx do
      MockClient.set_response(ctx.client, :get_info, {:ok, %{"balanceSat" => "500000"}})
      send(ctx.pid, :poll)
      :sys.get_state(ctx.pid)

      assert {:ok, 500_000} = Monitor.get_balance(ctx.table)
    end

    test "handles float balance from API", ctx do
      MockClient.set_response(ctx.client, :get_info, {:ok, %{"balanceSat" => 500_000.7}})
      send(ctx.pid, :poll)
      :sys.get_state(ctx.pid)

      assert {:ok, 500_000} = Monitor.get_balance(ctx.table)
    end

    test "handles non-numeric string balance by skipping poll", ctx do
      MockClient.set_response(ctx.client, :get_info, {:ok, %{"balanceSat" => "not_a_number"}})
      send(ctx.pid, :poll)
      :sys.get_state(ctx.pid)

      # Balance should not be updated — stays at :not_found
      assert {:error, :not_found} = Monitor.get_balance(ctx.table)
      assert Process.alive?(ctx.pid)
    end

    test "handles nil balance by skipping poll", ctx do
      MockClient.set_response(ctx.client, :get_info, {:ok, %{"balanceSat" => nil}})
      send(ctx.pid, :poll)
      :sys.get_state(ctx.pid)

      # Balance should not be updated — stays at :not_found
      assert {:error, :not_found} = Monitor.get_balance(ctx.table)
      assert Process.alive?(ctx.pid)
    end

    test "handles decimal string via partial parse", ctx do
      MockClient.set_response(ctx.client, :get_info, {:ok, %{"balanceSat" => "123.45"}})
      send(ctx.pid, :poll)
      :sys.get_state(ctx.pid)

      assert {:ok, 123} = Monitor.get_balance(ctx.table)
    end
  end

  describe "config validation" do
    test "rejects poll_interval: 0" do
      n = System.unique_integer([:positive])
      pubsub = :"liq_val_pubsub_#{n}"
      client_name = :"liq_val_client_#{n}"
      start_supervised!({Registry, keys: :duplicate, name: pubsub}, id: pubsub)
      start_supervised!({MockClient, name: client_name}, id: {MockClient, client_name})

      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: msg}, _stacktrace}} =
               Monitor.start_link(
                 client: {MockClient, client_name},
                 pubsub: pubsub,
                 table_name: :"liq_val_#{n}",
                 poll_interval: 0,
                 name: :"liq_val_srv_#{n}"
               )

      assert msg =~ "poll_interval must be a positive integer"
    end

    test "rejects invalid watermark ordering (critical >= low)" do
      n = System.unique_integer([:positive])
      pubsub = :"liq_wm_pubsub_#{n}"
      client_name = :"liq_wm_client_#{n}"
      start_supervised!({Registry, keys: :duplicate, name: pubsub}, id: pubsub)
      start_supervised!({MockClient, name: client_name}, id: {MockClient, client_name})

      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: msg}, _stacktrace}} =
               Monitor.start_link(
                 client: {MockClient, client_name},
                 pubsub: pubsub,
                 table_name: :"liq_wm_#{n}",
                 critical_watermark: 200_000,
                 low_watermark: 100_000,
                 high_watermark: 1_000_000,
                 name: :"liq_wm_srv_#{n}"
               )

      assert msg =~ "watermarks must satisfy critical < low < high"
    end

    test "rejects invalid watermark ordering (low >= high)" do
      n = System.unique_integer([:positive])
      pubsub = :"liq_wm2_pubsub_#{n}"
      client_name = :"liq_wm2_client_#{n}"
      start_supervised!({Registry, keys: :duplicate, name: pubsub}, id: pubsub)
      start_supervised!({MockClient, name: client_name}, id: {MockClient, client_name})

      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: msg}, _stacktrace}} =
               Monitor.start_link(
                 client: {MockClient, client_name},
                 pubsub: pubsub,
                 table_name: :"liq_wm2_#{n}",
                 critical_watermark: 10_000,
                 low_watermark: 1_000_000,
                 high_watermark: 500_000,
                 name: :"liq_wm2_srv_#{n}"
               )

      assert msg =~ "watermarks must satisfy critical < low < high"
    end
  end

  describe "ETS cleanup on terminate" do
    test "deletes ETS table on stop", ctx do
      assert :ets.whereis(ctx.table) != :undefined
      stop_supervised!(Monitor)
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
end
