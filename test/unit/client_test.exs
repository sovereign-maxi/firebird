defmodule FireBird.ClientTest do
  use ExUnit.Case, async: true

  describe "behaviour callbacks" do
    test "defines create_invoice/3" do
      callbacks = FireBird.Client.behaviour_info(:callbacks)
      assert {:create_invoice, 3} in callbacks
    end

    test "defines pay_invoice/4" do
      callbacks = FireBird.Client.behaviour_info(:callbacks)
      assert {:pay_invoice, 4} in callbacks
    end

    test "defines get_balance/1" do
      callbacks = FireBird.Client.behaviour_info(:callbacks)
      assert {:get_balance, 1} in callbacks
    end

    test "defines get_incoming_payment/2" do
      callbacks = FireBird.Client.behaviour_info(:callbacks)
      assert {:get_incoming_payment, 2} in callbacks
    end

    test "defines get_info/1" do
      callbacks = FireBird.Client.behaviour_info(:callbacks)
      assert {:get_info, 1} in callbacks
    end

    test "defines health_check/1" do
      callbacks = FireBird.Client.behaviour_info(:callbacks)
      assert {:health_check, 1} in callbacks
    end

    test "defines send_onchain/4 as optional" do
      callbacks = FireBird.Client.behaviour_info(:callbacks)
      optional = FireBird.Client.behaviour_info(:optional_callbacks)
      assert {:send_onchain, 4} in callbacks
      assert {:send_onchain, 4} in optional
    end

    test "defines exactly 8 callbacks" do
      callbacks = FireBird.Client.behaviour_info(:callbacks)
      assert length(callbacks) == 8
    end
  end
end
