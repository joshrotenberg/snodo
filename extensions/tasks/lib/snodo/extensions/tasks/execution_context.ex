defmodule Snodo.Extensions.Tasks.ExecutionContext do
  @moduledoc """
  Constructs the deliberately detached context supplied to a Tasks worker.

  Protocol identity, negotiated data, server configuration, the
  application-projected principal, and the request method remain available to
  the tool and the authorization policy. Request-only transport authority,
  session state, progress, cancellation, tracing metadata, request params, and
  the original request identifier do not cross the asynchronous boundary.
  """

  alias Snodo.Context
  alias Snodo.Transport.Context, as: TransportContext

  @spec detach(Context.t()) :: Context.t()
  def detach(%Context{} = request) do
    %Context{
      protocol_version: request.protocol_version,
      protocol: request.protocol,
      client_info: request.client_info,
      server_info: request.server_info,
      auth: request.auth,
      request_method: request.request_method,
      transport: %TransportContext{transport: :task},
      client_capabilities: request.client_capabilities,
      server_capabilities: request.server_capabilities,
      extensions: request.extensions,
      extension_options: request.extension_options
    }
  end
end
