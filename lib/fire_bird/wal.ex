defmodule FireBird.WAL do
  @moduledoc """
  Optional write-ahead log behaviour for crash-safe payment persistence.

  `Executor` calls `append/2` before dispatching a payment task and on
  every state transition, and `recover/1` during `init/1` if a WAL is
  configured. The `config` argument is passed through from supervisor
  configuration, supporting multiple instances.

  `recover/1` must return entries in append order (oldest first) — the
  executor takes the last record per payment hash as the truth.
  """

  @callback append(config :: term(), entry :: term()) :: :ok | {:error, term()}
  @callback recover(config :: term()) :: {:ok, [term()]} | {:error, term()}
end
