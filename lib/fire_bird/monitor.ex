defmodule FireBird.Monitor do
  @moduledoc """
  Periodic balance polling with configurable threshold alerts.

  Polls the Phoenixd node balance at regular intervals and publishes
  liquidity events when balance crosses watermark thresholds.

  ## Options
    - `:client` — `{module, config}` tuple implementing `FireBird.Client`
    - `:pubsub` — PubSub registry name
    - `:table_name` — ETS table name (default: `FireBird.Monitor`)
    - `:poll_interval` — Polling interval in ms (default: 30_000)
    - `:high_watermark` — Recovery threshold in sats (default: 1_000_000)
    - `:low_watermark` — Low alert threshold in sats (default: 100_000)
    - `:critical_watermark` — Critical alert threshold in sats (default: 10_000)
  """

  use GenServer

  alias FireBird.Events.{LiquidityCritical, LiquidityLow, LiquidityRecovered}
  alias FireBird.PubSub
  alias FireBird.Util

  require Logger

  defstruct [
    :client_mod,
    :client_config,
    :pubsub,
    :table_name,
    :poll_interval,
    :high_watermark,
    :low_watermark,
    :critical_watermark,
    :timer_ref,
    liquidity_state: :normal
  ]

  @default_poll_interval 30_000
  @default_high_watermark 1_000_000
  @default_low_watermark 100_000
  @default_critical_watermark 10_000

  @doc "Starts the liquidity monitor."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Returns the current balance from ETS."
  @spec get_balance(atom()) :: {:ok, non_neg_integer()} | {:error, :not_found}
  def get_balance(table_name \\ __MODULE__) do
    case :ets.lookup(table_name, :balance) do
      [{:balance, sats}] -> {:ok, sats}
      [] -> {:error, :not_found}
    end
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    {client_mod, client_config} = Keyword.fetch!(opts, :client)
    pubsub = Keyword.fetch!(opts, :pubsub)
    table_name = Keyword.get(opts, :table_name, __MODULE__)
    poll_interval = Keyword.get(opts, :poll_interval, @default_poll_interval)

    Util.validate_positive!("FireBird.Monitor", :poll_interval, poll_interval)

    high_watermark = Keyword.get(opts, :high_watermark, @default_high_watermark)
    low_watermark = Keyword.get(opts, :low_watermark, @default_low_watermark)
    critical_watermark = Keyword.get(opts, :critical_watermark, @default_critical_watermark)

    Util.validate_positive!("FireBird.Monitor", :high_watermark, high_watermark)
    Util.validate_positive!("FireBird.Monitor", :low_watermark, low_watermark)
    Util.validate_positive!("FireBird.Monitor", :critical_watermark, critical_watermark)
    validate_watermark_order!(critical_watermark, low_watermark, high_watermark)

    :ets.new(table_name, [:named_table, :set, :public, read_concurrency: true])

    state = %__MODULE__{
      client_mod: client_mod,
      client_config: client_config,
      pubsub: pubsub,
      table_name: table_name,
      poll_interval: poll_interval,
      high_watermark: high_watermark,
      low_watermark: low_watermark,
      critical_watermark: critical_watermark
    }

    timer_ref = schedule_poll(poll_interval)
    {:ok, %{state | timer_ref: timer_ref}}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    state = poll_balance(state)
    timer_ref = schedule_poll(state.poll_interval)
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  def handle_info(msg, state) do
    Logger.debug("Monitor: unexpected message #{inspect(msg)}")
    {:noreply, state}
  end

  defp poll_balance(state) do
    case state.client_mod.get_info(state.client_config) do
      {:ok, info} ->
        balance = info["balanceSat"] || info["balance"] || sum_channel_balance(info)

        case Util.parse_integer(balance) do
          {:ok, balance_sats} ->
            :ets.insert(state.table_name, {:balance, balance_sats})
            store_inbound_liquidity(state.table_name, info)

            :telemetry.execute(
              [:fire_bird, :liquidity, :poll],
              %{balance_sats: balance_sats},
              %{state: state.liquidity_state}
            )

            check_thresholds(state, balance_sats)

          :error ->
            Logger.warning("Monitor: unparseable balance: #{inspect(balance)}, skipping poll")

            state
        end

      {:error, reason} ->
        Logger.warning("Monitor: poll failed: #{inspect(reason)}")
        state
    end
  end

  defp store_inbound_liquidity(table, %{"channels" => channels}) when is_list(channels) do
    inbound =
      channels
      |> Enum.filter(&(&1["state"] == "Normal"))
      |> Enum.reduce(0, fn ch, acc ->
        case Util.parse_integer(ch["inboundLiquiditySat"]) do
          {:ok, sats} -> acc + sats
          :error -> acc
        end
      end)

    :ets.insert(table, {:inbound_liquidity, inbound})
  end

  defp store_inbound_liquidity(_table, _info), do: :ok

  defp sum_channel_balance(%{"channels" => channels}) when is_list(channels) do
    channels
    |> Enum.filter(&(&1["state"] == "Normal"))
    |> Enum.reduce(0, fn ch, acc ->
      case Util.parse_integer(ch["balanceSat"]) do
        {:ok, sats} -> acc + sats
        :error -> acc
      end
    end)
  end

  defp sum_channel_balance(_other), do: nil

  defp check_thresholds(state, balance_sats) do
    cond do
      balance_sats <= state.critical_watermark and state.liquidity_state != :critical ->
        publish_event(state, %LiquidityCritical{
          balance_sats: balance_sats,
          threshold_sats: state.critical_watermark
        })

        emit_threshold_event(balance_sats, state.liquidity_state, :critical)
        %{state | liquidity_state: :critical}

      balance_sats <= state.low_watermark and balance_sats > state.critical_watermark and
          state.liquidity_state != :low ->
        publish_event(state, %LiquidityLow{
          balance_sats: balance_sats,
          threshold_sats: state.low_watermark
        })

        emit_threshold_event(balance_sats, state.liquidity_state, :low)
        %{state | liquidity_state: :low}

      balance_sats >= state.high_watermark and state.liquidity_state != :normal ->
        publish_event(state, %LiquidityRecovered{
          balance_sats: balance_sats,
          threshold_sats: state.high_watermark
        })

        emit_threshold_event(balance_sats, state.liquidity_state, :normal)
        %{state | liquidity_state: :normal}

      true ->
        state
    end
  end

  defp emit_threshold_event(balance_sats, from, to) do
    :telemetry.execute(
      [:fire_bird, :liquidity, :threshold_crossed],
      %{balance_sats: balance_sats},
      %{from: from, to: to}
    )
  end

  defp publish_event(state, event) do
    topic = PubSub.topic_for_event(event)
    PubSub.publish(state.pubsub, topic, event)
  end

  @impl GenServer
  def terminate(_reason, state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

    if :ets.whereis(state.table_name) != :undefined do
      :ets.delete(state.table_name)
    end

    :ok
  end

  defp schedule_poll(interval), do: Process.send_after(self(), :poll, interval)

  defp validate_watermark_order!(critical, low, high)
       when critical < low and low < high,
       do: :ok

  defp validate_watermark_order!(critical, low, high) do
    raise ArgumentError,
          "Monitor: watermarks must satisfy " <>
            "critical < low < high, got: critical=#{critical}, low=#{low}, high=#{high}"
  end
end
