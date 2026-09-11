# FireBird

Lightning Network integration via the Phoenixd daemon REST API. Manages invoices, outbound payments (BOLT11, BOLT12 offers, LN Address / LUD-06+LUD-16), and liquidity monitoring.

Source: [github.com/sovereign-maxi/firebird](https://github.com/sovereign-maxi/firebird)

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
│  │ (state mach) │  │ (retry/exp)  │  │  (9 event structs)   │   │
│  └──────────────┘  └──────────────┘  └──────────────────────┘   │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐   │
│  │    Bolt11    │  │    Fees      │  │        HTTP          │   │
│  │ (amt parser) │  │ (PPM calc)   │  │ (Phoenixd client)    │   │
│  └──────────────┘  └──────────────┘  └──────────────────────┘   │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐   │
│  │    Lnurl     │  │  Monitor     │  │      Manager         │   │
│  │ (LUD-06/16)  │  │ (liquidity)  │  │    (invoices)        │   │
│  └──────────────┘  └──────────────┘  └──────────────────────┘   │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐   │
│  │  Executor    │  │  Webhook     │  │      Cleaner         │   │
│  │ (payments)   │  │ (Plug rtr)   │  │ (webhook dedup TTL)  │   │
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
| `FireBird.Payment` | Payment state machine with exponential backoff retry; BOLT11 / BOLT12 offer / LN Address destinations |
| `FireBird.Events` | 9 event structs for invoice, payment, and liquidity lifecycle |
| `FireBird.Client` | Behaviour contract for Phoenixd API operations |
| `FireBird.WAL` | Optional write-ahead log behaviour (append + recover) |
| `FireBird.Bolt11` | Pure BOLT11 invoice amount + payment-hash parser |
| `FireBird.Fees` | Fee calculation with PPM, floor, and ceiling clamping |
| `FireBird.Lnurl` | LUD-06 / LUD-16 (Lightning Address) resolver with SSRF hardening |
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

# BOLT11 destination (legacy default)
bolt11_payment = Payment.new(
  payment_hash: hash,
  bolt11: "lnbc1000u1p...",
  amount_sats: 1_000,
  created_at: DateTime.utc_now(),
  fee_limit_sats: 25          # flat routing-fee cap forwarded to phoenixd
)

# BOLT12 offer — phoenixd fetches a per-payment invoice under the hood;
# ln_payment_hash is bound from the /payoffer response before
# mark_succeeded/4 accepts a preimage.
offer_payment = Payment.new(
  payment_hash: local_dedup_key,
  destination_type: :offer,
  destination: "lno1...",
  amount_sats: 1_000,
  created_at: DateTime.utc_now()
)

# Lightning Address (LUD-06 / LUD-16) — Executor resolves the address to
# a fresh bolt11 via FireBird.Lnurl.fetch_invoice/4 and then pays through
# the standard bolt11 path.
ln_addr_payment = Payment.new(
  payment_hash: local_dedup_key,
  destination_type: :ln_address,
  destination: "user@example.com",
  amount_sats: 1_000,
  created_at: DateTime.utc_now()
)

# Lifecycle: pending → in_flight → succeeded | retrying → exhausted | unknown
{:ok, in_flight} = Payment.mark_in_flight(bolt11_payment)
{:ok, succeeded} = Payment.mark_succeeded(in_flight, preimage, fee_sats)

# Retry with exponential backoff (max 3 attempts)
{:ok, failed} = Payment.mark_failed(in_flight, "route not found")
failed.status                     # :retrying
Payment.retriable?(failed)        # true
Payment.next_retry_delay(failed)  # 1_000 (ms, doubles each attempt)

# When a payment's outcome is indeterminate (HTTP timeout, task crash,
# ambiguous 5xx), it lands in :unknown. Consumers MUST NOT release the
# caller's reservation on this state — reconcile with the node first
# via Client.get_outgoing_payment_by_hash/2.
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

# All operations take config as first argument.
{:ok, invoice} = HTTP.create_invoice(config, 1_000, "coffee", 3600)     # 4th arg = expiry seconds (nil for phoenixd default)
{:ok, result}  = HTTP.pay_invoice(config, bolt11, 1_000, "payment", 10) # 5th arg = flat fee cap in sats (nil disables)
{:ok, result}  = HTTP.pay_offer(config, "lno1...", 1_000, "payment", 10)
{:ok, payment} = HTTP.get_outgoing_payment_by_hash(config, ln_payment_hash)
{:ok, balance} = HTTP.get_balance(config)
:ok            = HTTP.health_check(config)
```

### Lightning Address (LUD-06 / LUD-16)

```elixir
alias FireBird.Lnurl

# Resolve "user@example.com" → fresh bolt11 for a given amount.
{:ok, %{bolt11: bolt11, payment_hash: hash, callback_url: url}} =
  Lnurl.fetch_invoice("user@example.com", 1_000, MyApp.Finch)

# Or check that an address's LNURL-pay endpoint is reachable without
# consuming an invoice slot.
:ok = Lnurl.probe("user@example.com", MyApp.Finch)
```

The resolver is SSRF-hardened: HTTPS only, DNS re-checked on every
redirect (max 2), private/loopback/link-local addresses rejected before
TCP connect, 64 KiB response body cap, 3 s connect / 5 s total timeout.
`Executor` uses this internally for `destination_type: :ln_address`
payments — you rarely call it directly unless you're staging bolt11s
outside the standard executor path.

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
    critical_watermark: 10_000,
    max_concurrent: 10,
    wal: {MyApp.PaymentWAL, wal_config}   # optional
  ]}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

Or let FireBird supervise its own Finch pool via the `:finch` option:

```elixir
{FireBird.Supervisor, [
  client: {FireBird.HTTP, config},
  finch: [name: MyApp.Finch]
]}
```

The `rest_for_one` supervisor starts children in order:

1. **PubSub** registry
2. **Monitor** (balance polling)
3. **Manager** (invoice lifecycle)
4. **Executor** (async payments)
5. **Cleaner** (webhook dedup + rate-limit TTL sweeper)

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
| `InvoicePaid` | `payment_hash`, `amount_sats`, `received_sats`, `paid_at` | Invoice confirmed paid — consumers assert `received_sats >= amount_sats` |
| `InvoiceExpired` | `payment_hash`, `amount_sats`, `expired_at` | Invoice expired |

### Payment Events

| Event | Fields | Description |
|-------|--------|-------------|
| `PaymentSent` | `payment_hash`, `amount_sats`, `fee_sats`, `preimage` | Payment succeeded |
| `PaymentFailed` | `payment_hash`, `amount_sats`, `reason`, `attempt` | Attempt failed, may retry |
| `PaymentExhausted` | `payment_hash`, `amount_sats`, `reason`, `attempts` | All retries exhausted |
| `PaymentUnknown` | `payment_hash`, `amount_sats`, `reason`, `attempt`, `phoenixd_id` | Outcome indeterminate — reconcile before releasing reservations |

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
  def create_invoice(config, amount_sats, description, expiry_seconds), do: ...
  def pay_invoice(config, bolt11, amount_sats, description, fee_limit_sats), do: ...
  def pay_offer(config, offer, amount_sats, description, fee_limit_sats), do: ...
  def get_balance(config), do: ...
  def get_incoming_payment(config, payment_hash), do: ...
  def get_outgoing_payment(config, payment_id), do: ...
  def get_outgoing_payment_by_hash(config, ln_payment_hash), do: ...
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

Pass to supervisor as a `{module, config}` tuple: `wal: {MyApp.PaymentWAL, wal_config}`. `Executor` calls `append/2` when a payment is added to the WAL and `recover/1` on boot to re-drive in-flight payments after a crash.

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

MIT. See [LICENSE](LICENSE).
