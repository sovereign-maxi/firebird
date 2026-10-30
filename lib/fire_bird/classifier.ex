defmodule FireBird.Classifier do
  @moduledoc """
  Classifies phoenixd's `payment_failed` reason strings into the
  executor's retry buckets.

  phoenixd returns HTTP 200 for BOTH successful AND failed payment
  attempts — the actual outcome rides as a `type` discriminator in
  the JSON body. A failed payment surfaces as
  `{"type": "payment_failed", "paymentHash": "...", "reason": "..."}`
  where the reason string is the lightning-kmp payment-failure
  explain output. Mapping those free-form strings to the executor's
  three retry buckets (retryable / definitive / connection-ambiguous)
  is self-contained here so `FireBird.Executor` doesn't need to pull
  the `String` module into its already-dense alias set.

  Unknown reasons fall through to `:connection_ambiguous` because an
  unrecognized reason is not positive proof that the payment did not
  settle. The reconciler must obtain a terminal node-side outcome
  before releasing any reservation.
  """

  @typedoc """
  The classification bucket for `FireBird.Executor` to route the
  outcome through.
  """
  @type kind ::
          :route_not_found
          | :insufficient_liquidity
          | :temporary_channel_failure
          | :connection_ambiguous
          | :definitive

  @spec classify(binary()) :: kind()
  def classify(reason) when is_binary(reason) do
    lowered = String.downcase(reason)

    cond do
      String.contains?(lowered, "routenotfound") or String.contains?(lowered, "no route") ->
        :route_not_found

      String.contains?(lowered, "temporarychannelfailure") or
        String.contains?(lowered, "temporaryremotefailure") or
          String.contains?(lowered, "temporarynodefailure") ->
        :temporary_channel_failure

      String.contains?(lowered, "recipientliquidity") or
        String.contains?(lowered, "insufficient liquidity") or
          String.contains?(lowered, "trampolinefeeinsufficient") ->
        :insufficient_liquidity

      String.contains?(lowered, "channelnotconnected") or
          String.contains?(lowered, "channelclosing") ->
        # Connection state uncertain — the payment may still land
        # when the channel reconnects. Fail-closed so the reconciler
        # drives it off the authoritative node view.
        :connection_ambiguous

      String.contains?(lowered, "insufficientbalance") ->
        :definitive

      true ->
        # Unrecognized reasons are not positive proof of non-settlement.
        :connection_ambiguous
    end
  end

  def classify(_other), do: :connection_ambiguous
end
