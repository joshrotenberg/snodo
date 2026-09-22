defmodule MCP.Progress.State do
  @moduledoc "Transport-owned immutable progress counters; no worker or global registry is created."

  alias MCP.Progress.Sink

  @type t :: %__MODULE__{sink: Sink.t(), last: number() | nil, count: non_neg_integer()}
  @enforce_keys [:sink]
  defstruct [:sink, :last, count: 0]
end
