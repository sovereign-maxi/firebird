defmodule FireBird do
  @moduledoc """
  Lightning Network integration via the Phoenixd daemon REST API.

  This package provides:

  - **Invoice** - Invoice state machine (pending → paid | expired)
  - **Payment** - Outbound payment state machine with retry/backoff
  - **Events** - Event structs for invoice, payment, and liquidity lifecycle
  - **Client** - Behaviour contract for Phoenixd API operations
  - **WAL** - Optional write-ahead log behaviour for crash-safe payments
  - **Bolt11** - Pure BOLT11 invoice amount parser
  - **Fees** - Fee calculation with PPM, floor, and ceiling clamping
  - **PubSub** - Registry-based event publish/subscribe
  - **HTTP** - Phoenixd REST client implementing the Client behaviour
  - **Monitor** - Periodic balance polling with threshold alerts
  - **Manager** - Invoice lifecycle tracking via ETS
  - **Executor** - Async payment execution with Task-based concurrency
  - **Webhook** - Plug router for Phoenixd webhook callbacks
  - **Supervisor** - `rest_for_one` supervisor for all FireBird processes

  ## Design

  All configuration is injected via opts — zero `Application.get_env` calls.
  The `FireBird.Client` behaviour takes a config struct as its first argument,
  enabling multiple Phoenixd connections in a single BEAM node.

  ## Usage

      # Start the FireBird supervisor
      FireBird.Supervisor.start_link(
        client: {FireBird.HTTP, FireBird.HTTP.new(base_url: "http://localhost:9740", password: "hunter2")},
        pubsub_name: MyApp.FireBirdPubSub
      )

      # Subscribe to payment events
      FireBird.PubSub.subscribe(MyApp.FireBirdPubSub, :payment)
  """
end
