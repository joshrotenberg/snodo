defmodule MCP.Transport.StreamableHTTP.StreamResponse do
  @moduledoc """
  A transport-server-agnostic long-lived SSE response descriptor.

  Embedding HTTP stacks write the headers and acknowledgement, then use the
  contained `MCP.Subscription` lifecycle API to pull and shape events.
  """

  alias MCP.Subscription

  @type headers :: [{String.t(), String.t()}]
  @type t :: %__MODULE__{
          status: pos_integer(),
          headers: headers(),
          keepalive_ms: pos_integer(),
          subscription: Subscription.t()
        }

  @enforce_keys [:subscription]
  defstruct status: 200,
            headers: [
              {"content-type", "text/event-stream"},
              {"cache-control", "no-cache"},
              {"x-accel-buffering", "no"}
            ],
            keepalive_ms: 15_000,
            subscription: nil
end
