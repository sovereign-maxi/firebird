defmodule FireBird.Info do
  @moduledoc """
  Pure interpretation of phoenixd `getInfo` payloads.

  The one place in the system that decides "what does phoenixd's
  response mean for channel balance?" — every consumer (periodic
  monitor, cache-bypass fresh read, future callers) routes through
  here so sensor-readiness is decided exactly once.

  ## Readiness contract

  Returns `{:ok, non_neg_integer()}` when the response contains a
  trustworthy balance, `:unavailable` when it doesn't. "Channels
  exist but none are in `Normal` state" is explicitly
  `:unavailable`, not a confident zero — this is the invariant
  that keeps a phoenixd sync window from being read as a drained
  channel.

  ## Resolution order

    1. Top-level `"balanceSat"` or `"balance"` via
       `Util.parse_integer/1` (integer or numeric-string).
    2. Else sum `"balanceSat"` across channels whose
       `"state" == "Normal"`.
    3. `:unavailable` when: no top-level pair AND (no channels key,
       OR empty channels list, OR no `"Normal"` channel).
  """

  alias FireBird.Util

  @spec channel_balance_sats(map()) :: {:ok, non_neg_integer()} | :unavailable
  def channel_balance_sats(info) when is_map(info) do
    case Util.parse_integer(info["balanceSat"] || info["balance"]) do
      {:ok, n} when n >= 0 -> {:ok, n}
      _no_integer -> sum_normal_channels(info["channels"])
    end
  end

  def channel_balance_sats(_not_a_map), do: :unavailable

  defp sum_normal_channels(channels) when is_list(channels) and channels != [] do
    normal = Enum.filter(channels, &(&1["state"] == "Normal"))

    if normal == [] do
      :unavailable
    else
      sum =
        Enum.reduce(normal, 0, fn ch, acc ->
          case Util.parse_integer(ch["balanceSat"]) do
            {:ok, n} -> acc + n
            :error -> acc
          end
        end)

      {:ok, sum}
    end
  end

  defp sum_normal_channels(_absent_or_empty), do: :unavailable
end
