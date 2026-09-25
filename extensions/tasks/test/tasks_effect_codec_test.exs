defmodule Snodo.Extensions.Tasks.EffectCodecTest do
  use ExUnit.Case, async: true

  alias Snodo.Extensions.Tasks.EffectCodec

  @retry_at "2026-08-25T10:00:01.500Z"

  test "round-trips the exact version-one no-effect envelope" do
    encoded = %{"version" => 1, "kind" => "none"}

    assert {:ok, ^encoded} = EffectCodec.encode(%{})
    assert {:ok, %{}} = EffectCodec.decode(encoded)
  end

  test "round-trips accepted input responses without changing their JSON shape" do
    effects = %{
      accepted_input_responses: %{
        "answer" => %{"value" => 42}
      }
    }

    encoded = %{
      "version" => 1,
      "kind" => "acceptedInputResponses",
      "responses" => effects.accepted_input_responses
    }

    assert {:ok, ^encoded} = EffectCodec.encode(effects)
    assert {:ok, ^effects} = EffectCodec.decode(encoded)
  end

  test "round-trips scheduled and exhausted retry effects exactly" do
    scheduled = %{
      retry: %{
        disposition: :scheduled,
        retry_at: @retry_at,
        delay_ms: 1_500,
        retry_count: 1
      }
    }

    encoded_scheduled = %{
      "version" => 1,
      "kind" => "retry",
      "retry" => %{
        "disposition" => "scheduled",
        "retryAt" => @retry_at,
        "delayMs" => 1_500,
        "retryCount" => 1
      }
    }

    exhausted = %{
      retry: %{
        disposition: :exhausted,
        retry_at: nil,
        delay_ms: nil,
        retry_count: 1
      }
    }

    encoded_exhausted = %{
      "version" => 1,
      "kind" => "retry",
      "retry" => %{
        "disposition" => "exhausted",
        "retryAt" => nil,
        "delayMs" => nil,
        "retryCount" => 1
      }
    }

    assert {:ok, ^encoded_scheduled} = EffectCodec.encode(scheduled)
    assert {:ok, ^scheduled} = EffectCodec.decode(encoded_scheduled)
    assert {:ok, ^encoded_exhausted} = EffectCodec.encode(exhausted)
    assert {:ok, ^exhausted} = EffectCodec.decode(encoded_exhausted)
  end

  test "fails closed on unsupported, malformed, and noncanonical envelopes" do
    assert {:error, {:unsupported_effects_format, 2}} =
             EffectCodec.decode(%{"version" => 2, "kind" => "none"})

    invalid = [
      %{unknown: true},
      %{"version" => 1, "kind" => "none", "extra" => true},
      %{"version" => 1, "kind" => "acceptedInputResponses", "responses" => []},
      %{
        "version" => 1,
        "kind" => "retry",
        "retry" => %{
          "disposition" => "scheduled",
          "retryAt" => "not-a-timestamp",
          "delayMs" => 1_500,
          "retryCount" => 1
        }
      }
    ]

    for encoded <- invalid do
      assert {:error, _reason} = EffectCodec.decode(encoded)
    end

    assert {:error, :invalid_transition_effects} = EffectCodec.encode(%{unknown: true})

    assert {:error, :invalid_retry_effect} =
             EffectCodec.encode(%{
               retry: %{
                 disposition: :scheduled,
                 retry_at: "not-a-timestamp",
                 delay_ms: 1_500,
                 retry_count: 1
               }
             })
  end
end
