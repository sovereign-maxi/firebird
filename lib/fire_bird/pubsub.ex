defmodule FireBird.PubSub do
  @moduledoc """
  Registry-based event publish/subscribe for FireBird events.

  Wraps `Registry` to provide topic-based pub/sub. Events arrive as
  `{FireBird.PubSub, topic, event}` tuples in the subscriber's
  `handle_info/2`.

  ## Topics

  - `:invoice` — Invoice lifecycle events
  - `:payment` — Payment lifecycle events
  - `:liquidity` — Balance threshold events

  ## Usage

      # In your GenServer
      def init(_) do
        FireBird.PubSub.subscribe(MyApp.FireBirdPubSub, :payment)
        {:ok, %{}}
      end

      def handle_info({FireBird.PubSub, :payment, event}, state) do
        # Handle payment event
        {:noreply, state}
      end
  """

  alias FireBird.Events.{
    InvoiceExpired,
    InvoicePaid,
    LiquidityCritical,
    LiquidityLow,
    LiquidityRecovered,
    PaymentExhausted,
    PaymentFailed,
    PaymentSent,
    PaymentUnknown
  }

  @doc "Returns a child spec for the PubSub registry."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)

    %{
      id: name,
      start: {Registry, :start_link, [[keys: :duplicate, name: name]]}
    }
  end

  @doc "Subscribes the calling process to a topic."
  @spec subscribe(atom(), atom()) :: {:ok, pid()} | {:error, term()}
  def subscribe(registry, topic) do
    Registry.register(registry, topic, [])
  end

  @doc "Publishes an event to all subscribers of the given topic."
  @spec publish(atom(), atom(), term()) :: :ok
  def publish(registry, topic, event) do
    Registry.dispatch(registry, topic, fn entries ->
      for {pid, _value} <- entries do
        send(pid, {FireBird.PubSub, topic, event})
      end
    end)
  end

  @doc "Derives the topic for a given event struct."
  @spec topic_for_event(struct()) :: atom()
  def topic_for_event(%InvoicePaid{}), do: :invoice
  def topic_for_event(%InvoiceExpired{}), do: :invoice
  def topic_for_event(%PaymentSent{}), do: :payment
  def topic_for_event(%PaymentFailed{}), do: :payment
  def topic_for_event(%PaymentExhausted{}), do: :payment
  def topic_for_event(%PaymentUnknown{}), do: :payment
  def topic_for_event(%LiquidityLow{}), do: :liquidity
  def topic_for_event(%LiquidityCritical{}), do: :liquidity
  def topic_for_event(%LiquidityRecovered{}), do: :liquidity
end
