defmodule FireBird.WAL do
  @moduledoc """
  Optional write-ahead log behaviour for crash-safe payment persistence.

  `Executor` calls `append/2` in `terminate/2` and `recover/1`
  during `init/1` if a WAL is configured. The `config` argument is
  passed through from supervisor configuration, supporting multiple instances.
  """

  @callback append(config :: term(), entry :: term()) :: :ok | {:error, term()}
  @callback recover(config :: term()) :: {:ok, [term()]} | {:error, term()}
end
