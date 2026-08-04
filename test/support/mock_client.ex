defmodule FireBird.MockClient do
  @moduledoc false
  @behaviour FireBird.Client

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :temporary
    }
  end

  @doc "Starts the mock client agent."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)
    Agent.start_link(fn -> %{} end, name: name)
  end

  @doc "Sets the response for a given callback."
  @spec set_response(GenServer.server(), atom(), term()) :: :ok
  def set_response(agent, callback, response) do
    Agent.update(agent, &Map.put(&1, callback, response))
  end

  @doc "Returns the list of recorded calls for a given callback."
  @spec calls(GenServer.server(), atom()) :: [term()]
  def calls(agent, callback) do
    Agent.get(agent, &Map.get(&1, {callback, :calls}, []))
  end

  @impl FireBird.Client
  def create_invoice(agent, amount_sats, description) do
    record_call(agent, :create_invoice, {amount_sats, description})
    get_response(agent, :create_invoice)
  end

  @impl FireBird.Client
  def pay_invoice(agent, bolt11, amount_sats, description) do
    record_call(agent, :pay_invoice, {bolt11, amount_sats, description})
    get_response(agent, :pay_invoice)
  end

  @impl FireBird.Client
  def get_balance(agent) do
    record_call(agent, :get_balance, {})
    get_response(agent, :get_balance)
  end

  @impl FireBird.Client
  def get_incoming_payment(agent, payment_hash) do
    record_call(agent, :get_incoming_payment, {payment_hash})
    get_response(agent, :get_incoming_payment)
  end

  @impl FireBird.Client
  def get_info(agent) do
    record_call(agent, :get_info, {})
    get_response(agent, :get_info)
  end

  @impl FireBird.Client
  def get_outgoing_payment(agent, payment_id) do
    record_call(agent, :get_outgoing_payment, {payment_id})
    get_response(agent, :get_outgoing_payment)
  end

  @impl FireBird.Client
  def get_outgoing_payment_by_hash(agent, payment_hash) do
    record_call(agent, :get_outgoing_payment_by_hash, {payment_hash})
    get_response(agent, :get_outgoing_payment_by_hash)
  end

  @impl FireBird.Client
  def health_check(agent) do
    record_call(agent, :health_check, {})
    get_response(agent, :health_check)
  end

  defp record_call(agent, callback, args) do
    Agent.update(agent, fn state ->
      calls = Map.get(state, {callback, :calls}, [])
      Map.put(state, {callback, :calls}, calls ++ [args])
    end)
  end

  defp get_response(agent, callback) do
    response = Agent.get(agent, &Map.get(&1, callback, {:error, :not_configured}))

    case response do
      fun when is_function(fun, 0) -> fun.()
      value -> value
    end
  end
end
