defmodule FireBird do
  @moduledoc """
  Lightning Network integration via the Phoenixd daemon REST API:
  invoice + payment state machines, liquidity monitoring, webhook
  handling, and a supervision tree that composes them.

  Configuration is injected via opts (no `Application.get_env` calls);
  the `FireBird.Client` behaviour takes a config struct as its first
  argument, so multiple Phoenixd connections can coexist in one BEAM.

  See the README for usage and the per-module docs for the callback
  contracts.
  """
end
