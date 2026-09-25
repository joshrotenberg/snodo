defmodule Snodo.Transport.Policy do
  @moduledoc "Transport-neutral requirements declared by a protocol dialect."

  @type t :: %__MODULE__{
          allowed_methods: [String.t()],
          require_protocol_header?: boolean(),
          allow_session_id?: boolean(),
          allow_batching?: boolean(),
          stream_mode: :none | :sse,
          request_content_types: [String.t()],
          required_accept_types: [String.t()],
          required_headers: [String.t()],
          forbidden_headers: [String.t()],
          mirrored_headers: %{optional(String.t()) => mirror()}
        }

  @type mirror :: %{
          required(:path) => [String.t()],
          optional(:encoding) => :plain | :base64_sentinel
        }

  defstruct allowed_methods: [],
            require_protocol_header?: false,
            allow_session_id?: true,
            allow_batching?: false,
            stream_mode: :none,
            request_content_types: ["application/json"],
            required_accept_types: ["application/json", "text/event-stream"],
            required_headers: [],
            forbidden_headers: [],
            mirrored_headers: %{}
end
