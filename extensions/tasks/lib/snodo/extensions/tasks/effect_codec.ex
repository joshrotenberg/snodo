defmodule Snodo.Extensions.Tasks.EffectCodec do
  @moduledoc false

  alias Snodo.Extensions.Tasks.RetryPolicy
  alias Snodo.Extensions.Tasks.Task, as: ProtocolTask

  @format 1

  @spec encode(map()) :: {:ok, map()} | {:error, term()}
  def encode(%{} = effects) when map_size(effects) == 0 do
    {:ok, %{"version" => @format, "kind" => "none"}}
  end

  def encode(%{accepted_input_responses: responses} = effects)
      when map_size(effects) == 1 and is_map(responses) do
    {:ok,
     %{
       "version" => @format,
       "kind" => "acceptedInputResponses",
       "responses" => responses
     }}
  end

  def encode(%{retry: retry} = effects)
      when map_size(effects) == 1 and is_map(retry) do
    with {:ok, encoded_retry} <- encode_retry(retry) do
      {:ok, %{"version" => @format, "kind" => "retry", "retry" => encoded_retry}}
    end
  end

  def encode(_effects), do: {:error, :invalid_transition_effects}

  @spec decode(term()) :: {:ok, map()} | {:error, term()}
  def decode(%{"version" => @format, "kind" => "none"} = encoded)
      when map_size(encoded) == 2,
      do: {:ok, %{}}

  def decode(
        %{
          "version" => @format,
          "kind" => "acceptedInputResponses",
          "responses" => responses
        } = encoded
      )
      when map_size(encoded) == 3 and is_map(responses),
      do: {:ok, %{accepted_input_responses: responses}}

  def decode(%{"version" => @format, "kind" => "retry", "retry" => encoded_retry} = encoded)
      when map_size(encoded) == 3 do
    with {:ok, retry} <- decode_retry(encoded_retry) do
      {:ok, %{retry: retry}}
    end
  end

  def decode(%{"version" => version}) when version != @format,
    do: {:error, {:unsupported_effects_format, version}}

  def decode(_effects), do: {:error, :invalid_transition_effects}

  defp encode_retry(
         %{
           disposition: :scheduled,
           retry_at: retry_at,
           delay_ms: delay_ms,
           retry_count: retry_count
         } = retry
       )
       when map_size(retry) == 4 and is_integer(retry_count) and retry_count > 0 do
    if valid_retry_schedule?(retry_at, delay_ms) do
      {:ok,
       %{
         "disposition" => "scheduled",
         "retryAt" => retry_at,
         "delayMs" => delay_ms,
         "retryCount" => retry_count
       }}
    else
      {:error, :invalid_retry_effect}
    end
  end

  defp encode_retry(
         %{
           disposition: :exhausted,
           retry_at: nil,
           delay_ms: nil,
           retry_count: retry_count
         } = retry
       )
       when map_size(retry) == 4 and is_integer(retry_count) and retry_count >= 0 do
    {:ok,
     %{
       "disposition" => "exhausted",
       "retryAt" => nil,
       "delayMs" => nil,
       "retryCount" => retry_count
     }}
  end

  defp encode_retry(_retry), do: {:error, :invalid_retry_effect}

  defp decode_retry(
         %{
           "disposition" => "scheduled",
           "retryAt" => retry_at,
           "delayMs" => delay_ms,
           "retryCount" => retry_count
         } = retry
       )
       when map_size(retry) == 4 and is_integer(retry_count) and retry_count > 0 do
    if valid_retry_schedule?(retry_at, delay_ms) do
      {:ok,
       %{
         disposition: :scheduled,
         retry_at: retry_at,
         delay_ms: delay_ms,
         retry_count: retry_count
       }}
    else
      {:error, :invalid_retry_effect}
    end
  end

  defp decode_retry(
         %{
           "disposition" => "exhausted",
           "retryAt" => nil,
           "delayMs" => nil,
           "retryCount" => retry_count
         } = retry
       )
       when map_size(retry) == 4 and is_integer(retry_count) and retry_count >= 0 do
    {:ok,
     %{
       disposition: :exhausted,
       retry_at: nil,
       delay_ms: nil,
       retry_count: retry_count
     }}
  end

  defp decode_retry(_retry), do: {:error, :invalid_retry_effect}

  defp valid_retry_schedule?(retry_at, delay_ms) do
    ProtocolTask.valid_timestamp?(retry_at) and
      match?({:ok, %RetryPolicy{}}, RetryPolicy.new([delay_ms]))
  end
end
