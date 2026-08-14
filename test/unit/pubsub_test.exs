defmodule FireBird.PubSubTest do
  use ExUnit.Case, async: true

  alias FireBird.Events.{InvoicePaid, LiquidityLow, PaymentSent, PaymentUnknown}
  alias FireBird.PubSub

  setup do
    registry_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({PubSub, name: registry_name})
    %{registry: registry_name}
  end

  describe "subscribe/2 and publish/3" do
    test "subscriber receives published event", %{registry: registry} do
      PubSub.subscribe(registry, :invoice)

      event = %InvoicePaid{
        payment_hash: <<0::256>>,
        amount_sats: 1000,
        received_sats: 1000,
        paid_at: DateTime.utc_now()
      }

      PubSub.publish(registry, :invoice, event)

      assert_receive {FireBird.PubSub, :invoice, ^event}
    end

    test "subscriber does not receive events from other topics", %{registry: registry} do
      PubSub.subscribe(registry, :payment)

      event = %InvoicePaid{
        payment_hash: <<0::256>>,
        amount_sats: 1000,
        received_sats: 1000,
        paid_at: DateTime.utc_now()
      }

      PubSub.publish(registry, :invoice, event)

      refute_receive {FireBird.PubSub, _, _}, 50
    end

    test "multiple subscribers receive the same event", %{registry: registry} do
      PubSub.subscribe(registry, :payment)

      # Simulate second subscriber in another process
      test_pid = self()

      spawn(fn ->
        PubSub.subscribe(registry, :payment)
        send(test_pid, :subscribed)

        receive do
          msg -> send(test_pid, {:other_proc, msg})
        end
      end)

      assert_receive :subscribed

      event = %PaymentSent{
        payment_hash: <<0::256>>,
        amount_sats: 1000,
        fee_sats: 10,
        preimage: <<1::256>>
      }

      PubSub.publish(registry, :payment, event)

      assert_receive {FireBird.PubSub, :payment, ^event}
      assert_receive {:other_proc, {FireBird.PubSub, :payment, ^event}}
    end
  end

  describe "topic_for_event/1" do
    test "maps invoice events to :invoice" do
      assert PubSub.topic_for_event(%InvoicePaid{
               payment_hash: <<>>,
               amount_sats: 0,
               received_sats: 0,
               paid_at: DateTime.utc_now()
             }) == :invoice
    end

    test "maps payment events to :payment" do
      assert PubSub.topic_for_event(%PaymentSent{
               payment_hash: <<>>,
               amount_sats: 0,
               fee_sats: 0,
               preimage: <<>>
             }) == :payment
    end

    test "maps PaymentUnknown to :payment" do
      assert PubSub.topic_for_event(%PaymentUnknown{
               payment_hash: <<>>,
               amount_sats: 0,
               reason: "timeout",
               attempt: 1
             }) == :payment
    end

    test "maps liquidity events to :liquidity" do
      assert PubSub.topic_for_event(%LiquidityLow{balance_sats: 0, threshold_sats: 0}) ==
               :liquidity
    end
  end
end
