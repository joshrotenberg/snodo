defmodule MCP.Extensions.Tasks.ExecutionContext do
  @moduledoc """
  Constructs the deliberately detached context supplied to a Tasks worker.

  Protocol identity, negotiated data, server configuration, and the
  application-projected principal remain available to the tool. Request-only
  transport authority, session state, progress, cancellation, tracing metadata,
  and the original request identifier do not cross the asynchronous boundary.
  """

  alias MCP.Context
  alias MCP.Transport.Context, as: TransportContext

  @spec detach(Context.t()) :: Context.t()
  def detach(%Context{} = request) do
    %Context{
      protocol_version: request.protocol_version,
      protocol: request.protocol,
      client_info: request.client_info,
      server_info: request.server_info,
      auth: request.auth,
      transport: %TransportContext{transport: :task},
      client_capabilities: request.client_capabilities,
      server_capabilities: request.server_capabilities,
      extensions: request.extensions,
      extension_options: request.extension_options
    }
  end
end
