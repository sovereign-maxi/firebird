defmodule FireBird.InfoTest do
  @moduledoc """
  Unit coverage for `FireBird.Info.channel_balance_sats/1` — the
  one place in the system that decides what a phoenixd getInfo
  payload means for channel balance. The empty-Normal regression
  (returning a confident zero during sync) is the specific bug
  this primitive exists to prevent.
  """

  use ExUnit.Case, async: true

  alias FireBird.Info

  describe "channel_balance_sats/1" do
    test "top-level balanceSat wins; channels aggregator is not consulted" do
      info = %{"balanceSat" => 500_000, "channels" => [%{"state" => "Syncing"}]}
      assert Info.channel_balance_sats(info) == {:ok, 500_000}
    end

    test "falls back to top-level balance when balanceSat is absent; string-typed parses" do
      assert Info.channel_balance_sats(%{"balance" => "250000"}) == {:ok, 250_000}
    end

    test "sums only Normal channels when top-level keys absent" do
      info = %{
        "channels" => [
          %{"state" => "Normal", "balanceSat" => 400_000},
          %{"state" => "Syncing", "balanceSat" => 50_000}
        ]
      }

      assert Info.channel_balance_sats(info) == {:ok, 400_000}
    end

    test "channels exist but NONE are Normal → :unavailable (regression gate)" do
      # Pre-fix this returned {:ok, 0}, which fed the Monitor's
      # cache + telemetry + threshold check during every phoenixd
      # sync and tripped a stuck %LiquidityCritical{} latch.
      info = %{
        "channels" => [
          %{"state" => "Syncing", "balanceSat" => 400_000},
          %{"state" => "Reestablishing", "balanceSat" => 50_000}
        ]
      }

      assert Info.channel_balance_sats(info) == :unavailable
    end

    test "empty channels list → :unavailable" do
      assert Info.channel_balance_sats(%{"channels" => []}) == :unavailable
    end

    test "missing channels key with no top-level balance → :unavailable" do
      assert Info.channel_balance_sats(%{}) == :unavailable
    end

    test "non-map input → :unavailable" do
      assert Info.channel_balance_sats(nil) == :unavailable
      assert Info.channel_balance_sats([]) == :unavailable
    end
  end
end
