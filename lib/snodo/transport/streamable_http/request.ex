defmodule Snodo.Transport.StreamableHTTP.Request do
  @moduledoc "A server-agnostic HTTP request at the Streamable HTTP boundary."

  alias Snodo.Transport.Context, as: TransportContext

  @type t :: %__MODULE__{
          method: String.t(),
          path: String.t(),
          headers: TransportContext.headers(),
          body: binary(),
          peer: term(),
          connection_ref: term()
        }

  @enforce_keys [:method, :path, :headers, :body]
  defstruct [:peer, :connection_ref, method: "POST", path: "/mcp", headers: [], body: ""]
end
