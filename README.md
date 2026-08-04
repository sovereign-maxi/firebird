# FireBird

Lightning Network integration via the Phoenixd daemon REST API. Manages invoices, outbound payments, and liquidity monitoring.

## Installation

Add `fire_bird` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:fire_bird, path: "../firebird"}
  ]
end
```

## Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                           fire_bird                             │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐   │
│  │   Invoice    │  │   Payment    │  │       Events         │   │
│  │ (state mach) │  │ (retry/exp)  │  │  (8 event structs)   │   │
│  └──────────────┘  └──────────────┘  └──────────────────────┘   │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐   │
│  │    Bolt11    │  │    Fees      │  │        HTTP          │   │
│  │ (amt parser) │  │ (PPM calc)   │  │ (Phoenixd client)    │   │
│  └──────────────┘  └──────────────┘  └──────────────────────┘   │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐   │
│  │  Monitor     │  │  Manager     │  │    Executor          │   │
│  │ (liquidity)  │  │ (invoices)   │  │   (payments)         │   │
│  └──────────────┘  └──────────────┘  └──────────────────────┘   │
│                           │                                     │
│                    ┌──────┴───────┐                             │
│                    │    PubSub    │  Registry-based events      │
│                    └──────────────┘                             │
│                                                                 │
│  Behaviours (host app implements):                              │
│  ┌──────────────┐  ┌──────────────┐                             │
│  │    Client    │  │     WAL      │                             │
│  │  (HTTP API)  │  │ (optional)   │                             │
│  └──────────────┘  └──────────────┘                             │
└─────────────────────────────────────────────────────────────────┘
```

## Modules

| Module | Purpose |
|--------|---------|
| `FireBird.Invoice` | Invoice state machine: pending → paid \| expired |
| `FireBird.Payment` | Payment state machine with exponential backoff retry |
| `FireBird.Events` | 8 event structs for invoice, payment, and liquidity lifecycle |
| `FireBird.Client` | Behaviour contract for Phoenixd API operations |
| `FireBird.WAL` | Optional write-ahead log behaviour (append + recover) |
| `FireBird.Bolt11` | Pure BOLT11 invoice amount parser |
| `FireBird.Fees` | Fee calculation with PPM, floor, and ceiling clamping |
| `FireBird.PubSub` | Registry-based event publish/subscribe |
| `FireBird.HTTP` | Finch-based Phoenixd REST client implementing Client |
| `FireBird.Monitor` | Periodic balance polling with threshold alerts |
| `FireBird.Manager` | Invoice lifecycle tracking via ETS |
| `FireBird.Executor` | Async payment execution with Task-based concurrency |
| `FireBird.Webhook` | Plug router for Phoenixd webhook callbacks |
| `FireBird.Cleaner` | TTL-based cleanup of webhook dedup entries |
| `FireBird.Supervisor` | `rest_for_one` supervisor for all FireBird processes |

## Usage

### Invoice State Machine

```elixir
alias FireBird.Invoice

# Create a pending invoice
invoice = Invoice.new(
  payment_hash: hash,
  bolt11: "lnbc1000u1p...",
  amount_sats: 1_000,
  created_at: DateTime.utc_now(),
  expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
)

invoice.status  # :pending

# Mark as paid with preimage validation (SHA-256)
{:ok, paid} = Invoice.mark_paid(invoice, preimage)
paid.status  # :paid

# Mark as expired
{:ok, expired} = Invoice.mark_expired(invoice)

# Check expiry
Invoice.expired?(invoice)  # true/false
```

### Payment State Machine

```elixir
alias FireBird.Payment

# Create a pending payment
payment = Payment.new(
  payment_hash: hash,
  bolt11: "lnbc1000u1p...",
  amount_sats: 1_000,
  created_at: DateTime.utc_now()
)

# Lifecycle: pending → in_flight → succeeded | retrying → exhausted
{:ok, in_flight} = Payment.mark_in_flight(payment)
{:ok, succeeded} = Payment.mark_succeeded(in_flight, preimage, fee_sats)

# Retry with exponential backoff (max 3 attempts)
{:ok, failed} = Payment.mark_failed(in_flight, "route not found")
failed.status         # :retrying
Payment.retriable?(failed)       # true
Payment.next_retry_delay(failed)  # 1_000 (ms, doubles each attempt)
```

### BOLT11 Amount Parsing

```elixir
alias FireBird.Bolt11

{:ok, 100_000} = Bolt11.parse_amount("lnbc1m1p...")      # millibitcoin
{:ok, 10_000}  = Bolt11.parse_amount("lnbc100u1p...")     # microbitcoin
{:ok, 150}     = Bolt11.parse_amount("lnbc1500n1p...")    # nanobitcoin
{:ok, 1}       = Bolt11.parse_amount("lnbc10000p1p...")   # picobitcoin
```

### Fee Calculation

```elixir
alias FireBird.Fees

# Default: 1000 PPM (0.1%), min 1 sat, max 100k sats
Fees.calculate(1_000_000)  # 1000 sats

# Custom config
Fees.deposit_fee(500_000, fee_ppm: 5000, fee_min_sats: 10)
Fees.withdrawal_fee(500_000, fee_ppm: 2000, fee_max_sats: 500)
```

### HTTP Client

```elixir
alias FireBird.HTTP

# Create a client config
config = HTTP.new(
  base_url: "http://localhost:9740",
  password: "mypassword",
  finch_name: MyApp.Finch
)

# All operations take config as first argument
{:ok, invoice} = HTTP.create_invoice(config, 1_000, "coffee")
{:ok, result}  = HTTP.pay_invoice(config, bolt11, 1_000, "payment", 10)
{:ok, balance} = HTTP.get_balance(config)
:ok            = HTTP.health_check(config)
```

### PubSub

Registry-based event publish/subscribe:

```elixir
alias FireBird.PubSub

# Subscribe to topics
PubSub.subscribe(MyApp.FireBirdPubSub, :invoice)
PubSub.subscribe(MyApp.FireBirdPubSub, :payment)
PubSub.subscribe(MyApp.FireBirdPubSub, :liquidity)

# Events arrive as messages in handle_info:
def handle_info({FireBird.PubSub, :invoice, %FireBird.Events.InvoicePaid{} = event}, state) do
  # Handle paid invoice
  {:noreply, state}
end

# Derive topic from event struct
:payment = PubSub.topic_for_event(%FireBird.Events.PaymentSent{...})
```

### Supervisor

Start the full supervision tree:

```elixir
# In your application supervisor
config = FireBird.HTTP.new(
  base_url: "http://localhost:9740",
  password: "secret",
  finch_name: MyApp.Finch
)

children = [
  {Finch, name: MyApp.Finch},
  {FireBird.Supervisor, [
    client: {FireBird.HTTP, config},
    pubsub_name: MyApp.FireBirdPubSub,
    low_watermark: 100_000,
    high_watermark: 1_000_000,
    max_concurrent: 10
  ]}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

The `rest_for_one` supervisor starts children in order:

1. **PubSub** registry
2. **Monitor** (balance polling)
3. **Manager** (invoice lifecycle)
4. **Executor** (async payments)

### Webhook Handler

Mount in your Plug/Phoenix router:

```elixir
forward "/webhooks/lightning", FireBird.Webhook,
  webhook_secret: "shared_secret",
  invoice_manager: FireBird.Manager
```

Features HMAC-SHA256 signature verification, replay protection, event deduplication, and per-IP rate limiting.

## Events

### Invoice Events

| Event | Fields | Description |
|-------|--------|-------------|
| `InvoicePaid` | `payment_hash`, `amount_sats`, `paid_at` | Invoice confirmed paid |
| `InvoiceExpired` | `payment_hash`, `amount_sats`, `expired_at` | Invoice expired |

### Payment Events

| Event | Fields | Description |
|-------|--------|-------------|
| `PaymentSent` | `payment_hash`, `amount_sats`, `fee_sats`, `preimage` | Payment succeeded |
| `PaymentFailed` | `payment_hash`, `amount_sats`, `reason`, `attempt` | Attempt failed, may retry |
| `PaymentExhausted` | `payment_hash`, `amount_sats`, `reason`, `attempts` | All retries exhausted |

### Liquidity Events

| Event | Fields | Description |
|-------|--------|-------------|
| `LiquidityLow` | `balance_sats`, `threshold_sats` | Balance below low watermark |
| `LiquidityCritical` | `balance_sats`, `threshold_sats` | Balance below critical threshold |
| `LiquidityRecovered` | `balance_sats`, `threshold_sats` | Balance recovered above high watermark |

All events include a `version: 1` field for forward compatibility.

## Behaviours

### Client

The HTTP client is the default implementation. Swap it for testing or alternative backends:

```elixir
defmodule MyApp.MockClient do
  @behaviour FireBird.Client

  @impl FireBird.Client
  def create_invoice(config, amount_sats, description), do: ...
  def pay_invoice(config, bolt11, amount_sats, description, fee_limit_sats), do: ...
  def get_balance(config), do: ...
  def get_incoming_payment(config, payment_hash), do: ...
  def get_outgoing_payment(config, payment_id), do: ...
  def get_info(config), do: ...
  def health_check(config), do: ...

  # Optional
  def send_onchain(config, address, amount_sats, fee_rate_sat_per_vbyte), do: ...
end
```

### WAL (Optional)

Implement for crash-safe payment persistence:

```elixir
defmodule MyApp.PaymentWAL do
  @behaviour FireBird.WAL

  @impl FireBird.WAL
  def append(config, entry), do: ...

  @impl FireBird.WAL
  def recover(config), do: {:ok, [...]}
end
```

Pass to supervisor: `wal: MyApp.PaymentWAL`

## Architecture

- **Config via opts**: zero `Application.get_env` calls, all configuration injected
- **Client as `{module, config}` tuple**: stored in GenServer state, enables multiple connections
- **ETS module-named tables**: `FireBird.Manager`, `FireBird.Executor`, `FireBird.Monitor`, `FireBird.Webhook`
- **Registry PubSub**: uses Elixir `Registry` (not Phoenix.PubSub) for event delivery
- **WAL optional**: two-callback behaviour, `Executor` appends on terminate and recovers on init

## Development

### Pre-commit Hook

```bash
# Enable pre-commit hooks (format, credo, tests, dialyzer)
git config core.hooksPath hooks
```

### Testing

```bash
# Run all tests
mix test

# Run unit tests only
mix test test/unit/

# Run with coverage
mix coveralls

# Check code style
mix credo --strict
```

## Dependencies

```elixir
defp deps do
  [
    {:jason, "~> 1.4"},
    {:finch, "~> 0.19"},
    {:plug, "~> 1.16"},
    {:telemetry, "~> 1.3"}
  ]
end
```

## License

MIT
