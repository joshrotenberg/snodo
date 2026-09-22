defmodule MCP.Progress.Sink do
  @moduledoc "A request-scoped handle whose lifecycle belongs to its transport."

  @type t :: %__MODULE__{
          owner: pid(),
          reference: reference(),
          lifecycle: :atomics.atomics_ref(),
          timeout: pos_integer(),
          max_updates: pos_integer(),
          max_message_bytes: pos_integer()
        }
  @enforce_keys [:owner, :reference, :lifecycle, :timeout, :max_updates, :max_message_bytes]
  defstruct @enforce_keys
end
