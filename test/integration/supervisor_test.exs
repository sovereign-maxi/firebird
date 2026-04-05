defmodule FireBird.SupervisorTest do
  use ExUnit.Case, async: false

  alias FireBird.MockClient

  setup do
    n = System.unique_integer([:positive])

    client_name = :"sup_test_client_#{n}"
    start_supervised!({MockClient, name: client_name}, id: client_name)

    # Set a default balance response so LiquidityMonitor poll doesn't log warnings
    MockClient.set_response(client_name, :get_info, {:ok, %{"balanceSat" => 500_000}})

    %{n: n, client_name: client_name}
  end

  describe "child ordering" do
    test "starts all 5 children in correct order", ctx do
      sup_name = :"sup_order_#{ctx.n}"

      {:ok, sup_pid} =
        FireBird.Supervisor.start_link(
          client: {MockClient, ctx.client_name},
          name: sup_name,
          pubsub_name: :"sup_pubsub_#{ctx.n}",
          liquidity_table: :"sup_liq_#{ctx.n}",
          invoice_table: :"sup_inv_#{ctx.n}",
          payment_table: :"sup_pay_#{ctx.n}",
          dedup_table: :"sup_dedup_#{ctx.n}",
          rate_limit_table: :"sup_rate_#{ctx.n}",
          poll_interval: 600_000,
          invoice_poll_interval: 600_000,
          payment_cleanup_interval: 600_000,
          invoice_cleanup_interval: 600_000,
          dedup_interval_ms: 600_000
        )

      children = Supervisor.which_children(sup_name)
      child_modules = Enum.map(children, fn {_id, _pid, _type, [mod]} -> mod end)

      # Children are listed in reverse start order by Supervisor.which_children
      assert Enum.reverse(child_modules) == [
               Registry,
               FireBird.Monitor,
               FireBird.Manager,
               FireBird.Executor,
               FireBird.Cleaner
             ]

      # All children are alive
      for {_id, pid, _type, _mods} <- children do
        assert is_pid(pid)
        assert Process.alive?(pid)
      end

      Supervisor.stop(sup_pid)
    end
  end

  describe "strategy" do
    test "uses rest_for_one strategy", ctx do
      sup_name = :"sup_strategy_#{ctx.n}"

      {:ok, sup_pid} =
        FireBird.Supervisor.start_link(
          client: {MockClient, ctx.client_name},
          name: sup_name,
          pubsub_name: :"sup_strat_pubsub_#{ctx.n}",
          liquidity_table: :"sup_strat_liq_#{ctx.n}",
          invoice_table: :"sup_strat_inv_#{ctx.n}",
          payment_table: :"sup_strat_pay_#{ctx.n}",
          dedup_table: :"sup_strat_dedup_#{ctx.n}",
          rate_limit_table: :"sup_strat_rate_#{ctx.n}",
          poll_interval: 600_000,
          invoice_poll_interval: 600_000,
          payment_cleanup_interval: 600_000,
          invoice_cleanup_interval: 600_000,
          dedup_interval_ms: 600_000
        )

      # Get PID of InvoiceManager (third child)
      children_before = Supervisor.which_children(sup_name)

      invoice_mgr_before =
        Enum.find_value(children_before, fn
          {_id, pid, _type, [FireBird.Manager]} -> pid
          _other -> nil
        end)

      payment_exec_before =
        Enum.find_value(children_before, fn
          {_id, pid, _type, [FireBird.Executor]} -> pid
          _other -> nil
        end)

      dedup_before =
        Enum.find_value(children_before, fn
          {_id, pid, _type, [FireBird.Cleaner]} -> pid
          _other -> nil
        end)

      # Kill InvoiceManager — rest_for_one should restart it + later children
      Process.exit(invoice_mgr_before, :kill)

      FireBirdHelpers.await_condition(fn ->
        Enum.find_value(Supervisor.which_children(sup_name), fn
          {_id, pid, _type, [FireBird.Manager]} when is_pid(pid) ->
            pid != invoice_mgr_before and Process.alive?(pid)

          _other ->
            false
        end)
      end)

      children_after = Supervisor.which_children(sup_name)

      invoice_mgr_after =
        Enum.find_value(children_after, fn
          {_id, pid, _type, [FireBird.Manager]} -> pid
          _other -> nil
        end)

      payment_exec_after =
        Enum.find_value(children_after, fn
          {_id, pid, _type, [FireBird.Executor]} -> pid
          _other -> nil
        end)

      dedup_after =
        Enum.find_value(children_after, fn
          {_id, pid, _type, [FireBird.Cleaner]} -> pid
          _other -> nil
        end)

      # InvoiceManager was restarted (new PID)
      assert invoice_mgr_after != invoice_mgr_before
      assert Process.alive?(invoice_mgr_after)

      # PaymentExecutor and DedupCleaner were also restarted (rest_for_one)
      assert payment_exec_after != payment_exec_before
      assert Process.alive?(payment_exec_after)

      assert dedup_after != dedup_before
      assert Process.alive?(dedup_after)

      Supervisor.stop(sup_pid)
    end
  end

  describe "option passthrough" do
    test "custom table names are used by children", ctx do
      sup_name = :"sup_opts_#{ctx.n}"
      liq_table = :"custom_liq_#{ctx.n}"
      inv_table = :"custom_inv_#{ctx.n}"
      pay_table = :"custom_pay_#{ctx.n}"

      {:ok, sup_pid} =
        FireBird.Supervisor.start_link(
          client: {MockClient, ctx.client_name},
          name: sup_name,
          pubsub_name: :"sup_opts_pubsub_#{ctx.n}",
          liquidity_table: liq_table,
          invoice_table: inv_table,
          payment_table: pay_table,
          dedup_table: :"sup_opts_dedup_#{ctx.n}",
          rate_limit_table: :"sup_opts_rate_#{ctx.n}",
          poll_interval: 600_000,
          invoice_poll_interval: 600_000,
          payment_cleanup_interval: 600_000,
          invoice_cleanup_interval: 600_000,
          dedup_interval_ms: 600_000
        )

      # ETS tables should exist with the custom names
      assert :ets.whereis(liq_table) != :undefined
      assert :ets.whereis(inv_table) != :undefined
      assert :ets.whereis(pay_table) != :undefined

      Supervisor.stop(sup_pid)
    end

    test "custom max_concurrent is passed to PaymentExecutor", ctx do
      sup_name = :"sup_maxc_#{ctx.n}"

      {:ok, sup_pid} =
        FireBird.Supervisor.start_link(
          client: {MockClient, ctx.client_name},
          name: sup_name,
          pubsub_name: :"sup_maxc_pubsub_#{ctx.n}",
          liquidity_table: :"sup_maxc_liq_#{ctx.n}",
          invoice_table: :"sup_maxc_inv_#{ctx.n}",
          payment_table: :"sup_maxc_pay_#{ctx.n}",
          dedup_table: :"sup_maxc_dedup_#{ctx.n}",
          rate_limit_table: :"sup_maxc_rate_#{ctx.n}",
          max_concurrent: 1,
          poll_interval: 600_000,
          invoice_poll_interval: 600_000,
          payment_cleanup_interval: 600_000,
          invoice_cleanup_interval: 600_000,
          dedup_interval_ms: 600_000
        )

      # PaymentExecutor should respect max_concurrent: 1
      # Submit a blocking payment, then verify second is rejected
      MockClient.set_response(ctx.client_name, :pay_invoice, fn ->
        Process.sleep(60_000)
        {:error, :timeout}
      end)

      p1 = FireBirdHelpers.build_payment()
      p2 = FireBirdHelpers.build_payment()

      assert :ok = FireBird.Executor.submit(FireBird.Executor, p1)
      assert {:error, :at_capacity} = FireBird.Executor.submit(FireBird.Executor, p2)

      Supervisor.stop(sup_pid)
    end

    test "custom watermarks are passed to LiquidityMonitor", ctx do
      Process.flag(:trap_exit, true)

      sup_name = :"sup_wm_#{ctx.n}"
      liq_table = :"sup_wm_liq_#{ctx.n}"
      pubsub = :"sup_wm_pubsub_#{ctx.n}"

      {:ok, sup_pid} =
        FireBird.Supervisor.start_link(
          client: {MockClient, ctx.client_name},
          name: sup_name,
          pubsub_name: pubsub,
          liquidity_table: liq_table,
          invoice_table: :"sup_wm_inv_#{ctx.n}",
          payment_table: :"sup_wm_pay_#{ctx.n}",
          dedup_table: :"sup_wm_dedup_#{ctx.n}",
          rate_limit_table: :"sup_wm_rate_#{ctx.n}",
          high_watermark: 500,
          low_watermark: 100,
          critical_watermark: 10,
          poll_interval: 600_000,
          invoice_poll_interval: 600_000,
          payment_cleanup_interval: 600_000,
          invoice_cleanup_interval: 600_000,
          dedup_interval_ms: 600_000
        )

      # Trigger a poll with balance below critical to verify watermarks took effect
      Registry.register(pubsub, :liquidity, [])

      MockClient.set_response(ctx.client_name, :get_info, {:ok, %{"balanceSat" => 5}})

      liq_pid =
        Enum.find_value(Supervisor.which_children(sup_name), fn
          {_id, pid, _type, [FireBird.Monitor]} -> pid
          _other -> nil
        end)

      send(liq_pid, :poll)

      assert_receive {FireBird.PubSub, :liquidity,
                      %FireBird.Events.LiquidityCritical{threshold_sats: 10}},
                     1_000

      Supervisor.stop(sup_pid)
    end
  end

  describe "optional finch child" do
    test "no Finch child when :finch option is omitted", ctx do
      sup_name = :"sup_no_finch_#{ctx.n}"

      {:ok, sup_pid} =
        FireBird.Supervisor.start_link(
          client: {MockClient, ctx.client_name},
          name: sup_name,
          pubsub_name: :"sup_nf_pubsub_#{ctx.n}",
          liquidity_table: :"sup_nf_liq_#{ctx.n}",
          invoice_table: :"sup_nf_inv_#{ctx.n}",
          payment_table: :"sup_nf_pay_#{ctx.n}",
          dedup_table: :"sup_nf_dedup_#{ctx.n}",
          rate_limit_table: :"sup_nf_rate_#{ctx.n}",
          poll_interval: 600_000,
          invoice_poll_interval: 600_000,
          payment_cleanup_interval: 600_000,
          invoice_cleanup_interval: 600_000,
          dedup_interval_ms: 600_000
        )

      children = Supervisor.which_children(sup_name)
      child_modules = Enum.flat_map(children, fn {_id, _pid, _type, mods} -> mods end)

      refute Finch in child_modules

      Supervisor.stop(sup_pid)
    end

    test "Finch child is prepended when :finch option is provided", ctx do
      sup_name = :"sup_finch_#{ctx.n}"
      finch_name = :"sup_finch_pool_#{ctx.n}"

      {:ok, sup_pid} =
        FireBird.Supervisor.start_link(
          client: {MockClient, ctx.client_name},
          name: sup_name,
          pubsub_name: :"sup_f_pubsub_#{ctx.n}",
          liquidity_table: :"sup_f_liq_#{ctx.n}",
          invoice_table: :"sup_f_inv_#{ctx.n}",
          payment_table: :"sup_f_pay_#{ctx.n}",
          dedup_table: :"sup_f_dedup_#{ctx.n}",
          rate_limit_table: :"sup_f_rate_#{ctx.n}",
          finch: [name: finch_name],
          poll_interval: 600_000,
          invoice_poll_interval: 600_000,
          payment_cleanup_interval: 600_000,
          invoice_cleanup_interval: 600_000,
          dedup_interval_ms: 600_000
        )

      children = Supervisor.which_children(sup_name)
      # Finch is the first started = last in which_children list
      {_id, finch_pid, _type, _mods} = List.last(children)
      assert is_pid(finch_pid)
      assert Process.alive?(finch_pid)

      # Total children: 6 (Finch + PubSub + 4 GenServers)
      assert length(children) == 6

      Supervisor.stop(sup_pid)
    end
  end

  describe "WAL passthrough to PaymentExecutor" do
    test "WAL recovery runs through full supervisor startup", ctx do
      sup_name = :"sup_wal_#{ctx.n}"
      pay_table = :"sup_wal_pay_#{ctx.n}"
      wal_name = :"sup_wal_agent_#{ctx.n}"

      start_supervised!({FireBird.MockWAL, name: wal_name}, id: wal_name)

      # Pre-populate WAL with an in-flight payment
      payment = FireBirdHelpers.build_payment(max_attempts: 3)
      in_flight = %{payment | status: :in_flight, attempt: 1}
      FireBird.MockWAL.append(wal_name, in_flight)

      preimage = :crypto.strong_rand_bytes(32)
      preimage_hex = Base.encode16(preimage, case: :lower)

      MockClient.set_response(
        ctx.client_name,
        :pay_invoice,
        {:ok, %{"preimage" => preimage_hex, "fees" => 0}}
      )

      pubsub_name = :"sup_wal_pubsub_#{ctx.n}"

      {:ok, sup_pid} =
        FireBird.Supervisor.start_link(
          client: {MockClient, ctx.client_name},
          name: sup_name,
          pubsub_name: pubsub_name,
          liquidity_table: :"sup_wal_liq_#{ctx.n}",
          invoice_table: :"sup_wal_inv_#{ctx.n}",
          payment_table: pay_table,
          dedup_table: :"sup_wal_dedup_#{ctx.n}",
          rate_limit_table: :"sup_wal_rate_#{ctx.n}",
          wal: {FireBird.MockWAL, wal_name},
          poll_interval: 600_000,
          invoice_poll_interval: 600_000,
          payment_cleanup_interval: 600_000,
          invoice_cleanup_interval: 600_000,
          dedup_interval_ms: 600_000
        )

      # Poll until WAL recovery completes
      FireBirdHelpers.await_condition(fn ->
        match?(
          {:ok, %{status: :succeeded}},
          FireBird.Executor.lookup(pay_table, payment.payment_hash)
        )
      end)

      assert {:ok, result} = FireBird.Executor.lookup(pay_table, payment.payment_hash)
      assert result.status == :succeeded

      Supervisor.stop(sup_pid)
    end
  end
end
