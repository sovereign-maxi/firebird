defmodule FireBirdHelpers do
  @moduledoc """
  Test helper functions for building FireBird structs and
  safe async synchronization primitives.
  """

  alias FireBird.Invoice
  alias FireBird.Payment

  @doc """
  Polls `fun` every 10ms until it returns a truthy value or `timeout_ms` expires.
  Raises on timeout.

  Use instead of `Process.sleep` when waiting for async state changes:

      await_condition(fn -> Executor.lookup(table, hash) != {:error, :not_found} end)
  """
  @spec await_condition((-> boolean()), pos_integer()) :: :ok
  def await_condition(fun, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_poll(fun, deadline)
  end

  defp do_poll(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        raise "await_condition timed out"
      end

      Process.sleep(10)
      do_poll(fun, deadline)
    end
  end

  @doc "Generates a random 32-byte payment hash."
  @spec random_payment_hash() :: binary()
  def random_payment_hash do
    :crypto.strong_rand_bytes(32)
  end

  @doc "Builds an invoice with sensible defaults. Override any field via opts."
  @spec build_invoice(keyword()) :: Invoice.t()
  def build_invoice(opts \\ []) do
    payment_hash = Keyword.get_lazy(opts, :payment_hash, &random_payment_hash/0)
    now = DateTime.utc_now()

    defaults = [
      payment_hash: payment_hash,
      bolt11:
        "lnbc#{:rand.uniform(1000)}u1p#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}",
      amount_sats: Keyword.get(opts, :amount_sats, 1_000),
      created_at: Keyword.get(opts, :created_at, now),
      expires_at: Keyword.get(opts, :expires_at, DateTime.add(now, 3600, :second))
    ]

    merged = Keyword.merge(defaults, opts)
    Invoice.new(merged)
  end

  @doc "Builds a payment with sensible defaults. Override any field via opts."
  @spec build_payment(keyword()) :: Payment.t()
  def build_payment(opts \\ []) do
    payment_hash = Keyword.get_lazy(opts, :payment_hash, &random_payment_hash/0)

    defaults = [
      payment_hash: payment_hash,
      bolt11:
        "lnbc#{:rand.uniform(1000)}u1p#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}",
      amount_sats: Keyword.get(opts, :amount_sats, 1_000),
      created_at: Keyword.get(opts, :created_at, DateTime.utc_now())
    ]

    merged = Keyword.merge(defaults, opts)
    Payment.new(merged)
  end
end
