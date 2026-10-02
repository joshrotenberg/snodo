defmodule Snodo.TraceContext do
  @moduledoc """
  Extracts bounded W3C trace context from request `_meta` without changing it.

  Invalid values are omitted from the extracted context. `tracestate` is only
  used with a valid `traceparent`, as required by W3C Trace Context. Applications
  that need the original metadata can read `Snodo.Context.metadata`.
  """

  @type t :: %{optional(String.t()) => String.t()}

  @hex ~r/\A[0-9a-f]+\z/
  @future_suffix ~r/\A(?:-[\x20-\x7e]*)?\z/
  @state_key ~r/\A[a-z0-9][a-z0-9_\-*\/@]{0,255}\z/
  @state_value ~r/\A[\x20-\x2b\x2d-\x3c\x3e-\x7e]{0,255}[\x21-\x2b\x2d-\x3c\x3e-\x7e]\z/
  @ows ~r/\A[ \t]+|[ \t]+\z/
  @zero_trace_id String.duplicate("0", 32)
  @zero_parent_id String.duplicate("0", 16)

  @doc "Returns valid trace fields from a request metadata map."
  @spec from_metadata(term()) :: t()
  def from_metadata(%{"traceparent" => parent} = metadata) do
    if valid_traceparent?(parent) do
      maybe_put_tracestate(%{"traceparent" => parent}, Map.get(metadata, "tracestate"))
    else
      %{}
    end
  end

  def from_metadata(_metadata), do: %{}

  defp maybe_put_tracestate(context, state) when is_binary(state) do
    if valid_tracestate?(state), do: Map.put(context, "tracestate", state), else: context
  end

  defp maybe_put_tracestate(context, _state), do: context

  @doc false
  @spec instrumentation_metadata(term()) :: map()
  def instrumentation_metadata(metadata) do
    case from_metadata(metadata) do
      %{"traceparent" => parent, "tracestate" => state} ->
        %{traceparent: parent, tracestate: state}

      %{"traceparent" => parent} ->
        %{traceparent: parent}

      _empty ->
        %{}
    end
  end

  @doc "Validates the named client option and returns protocol-native metadata."
  @spec client_metadata!(term()) :: map()
  def client_metadata!(%{"traceparent" => parent} = metadata) do
    extracted = from_metadata(metadata)
    keys = Map.keys(metadata)

    if Enum.all?(keys, &(&1 in ["traceparent", "tracestate"])) and
         Map.has_key?(extracted, "traceparent") and extracted["traceparent"] == parent and
         (not Map.has_key?(metadata, "tracestate") or
            (Map.has_key?(extracted, "tracestate") and
               extracted["tracestate"] == metadata["tracestate"])) do
      metadata
    else
      raise ArgumentError, ":trace_context must contain valid W3C traceparent and tracestate"
    end
  end

  def client_metadata!(_metadata) do
    raise ArgumentError, ":trace_context must contain valid W3C traceparent and tracestate"
  end

  defp valid_traceparent?(value)
       when is_binary(value) and byte_size(value) >= 55 and byte_size(value) <= 512 do
    case value do
      <<version::binary-size(2), "-", trace_id::binary-size(32), "-", parent_id::binary-size(16),
        "-", flags::binary-size(2), suffix::binary>> ->
        valid_version?(version, suffix) and valid_trace_id?(trace_id) and
          valid_parent_id?(parent_id) and hex?(flags)

      _other ->
        false
    end
  end

  defp valid_traceparent?(_value), do: false

  defp valid_version?("ff", _suffix), do: false
  defp valid_version?("00", suffix), do: suffix == ""
  defp valid_version?(version, suffix), do: hex?(version) and Regex.match?(@future_suffix, suffix)

  defp valid_trace_id?(trace_id), do: trace_id != @zero_trace_id and hex?(trace_id)
  defp valid_parent_id?(parent_id), do: parent_id != @zero_parent_id and hex?(parent_id)
  defp hex?(value), do: Regex.match?(@hex, value)

  defp valid_tracestate?(value) when is_binary(value) and byte_size(value) <= 512 do
    members = String.split(value, ",", trim: false)

    if length(members) <= 32 do
      Enum.reduce_while(members, MapSet.new(), &accumulate_state_member/2) != :invalid
    else
      false
    end
  end

  defp valid_tracestate?(_value), do: false

  defp accumulate_state_member(member, keys) do
    member = Regex.replace(@ows, member, "")

    case String.split(member, "=", parts: 2) do
      [""] -> {:cont, keys}
      [key, state] -> accumulate_key_value(key, state, keys)
      _other -> {:halt, :invalid}
    end
  end

  defp accumulate_key_value(key, state, keys) do
    if valid_state_member?(key, state) and not MapSet.member?(keys, key),
      do: {:cont, MapSet.put(keys, key)},
      else: {:halt, :invalid}
  end

  defp valid_state_member?(key, state) do
    Regex.match?(@state_key, key) and Regex.match?(@state_value, state)
  end
end
