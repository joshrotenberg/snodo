defmodule Snodo.Protocol.ToolResult do
  @moduledoc false

  @spec structured_content(term()) :: [%{required(String.t()) => String.t()}]
  def structured_content(value), do: [%{"type" => "text", "text" => JSON.encode!(value)}]

  # snodo_proxy uses this when forwarding completed backend tool results.
  @spec put_structured_fallback(map()) :: map()
  def put_structured_fallback(%{"content" => _content} = result), do: result

  def put_structured_fallback(%{"structuredContent" => value} = result),
    do: Map.put(result, "content", structured_content(value))

  def put_structured_fallback(result), do: result
end
