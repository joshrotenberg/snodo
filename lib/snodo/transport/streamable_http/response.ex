defmodule Snodo.Transport.StreamableHTTP.Response do
  @moduledoc "A complete HTTP response returned by the core adapter."

  @type headers :: [{String.t(), String.t()}]
  @type t :: %__MODULE__{status: pos_integer(), headers: headers(), body: binary()}

  @enforce_keys [:status]
  defstruct status: 200, headers: [], body: ""
end
