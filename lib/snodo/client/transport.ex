defmodule Snodo.Client.Transport do
  @moduledoc """
  Behaviour for the connection underneath `Snodo.Client`.

  A transport moves one complete JSON-RPC request to a server and returns the
  complete JSON-RPC response. `Snodo.Client` builds the request and decodes the
  response, so a transport never interprets `result` or `error`.

  `request/3` receives these options:

    * `:timeout` - milliseconds to wait for the response.
    * `:dialect` - the protocol dialect module that built the request. HTTP
      uses its `transport_policy/1` to derive headers.
    * `:on_progress` - present when the caller asked for progress. A function
      of one argument to call, in the process that called `request/3`, with
      the `params` of each `notifications/progress` whose `progressToken` is
      the request's `params["_meta"]["progressToken"]`, before returning the
      response.
    * `:reset_timeout_on_progress` - when `true`, each delivered progress
      notification restarts `:timeout`, up to `:max_total_timeout`
      milliseconds after the request started. Past that the request fails
      with `max_total_timeout_error/1`.

  A transport that ignores the progress options delivers no progress and keeps
  a fixed timeout.

  The optional `listen/3` opens a `subscriptions/listen` stream for
  `Snodo.Client.listen/3`. It sends the request, waits `:timeout` milliseconds
  for the server's `notifications/subscriptions/acknowledged`, and returns
  `{:ok, accepted_filter, pid}`: the filter from the acknowledgement and the
  process that receives the stream. That process keeps a
  `Snodo.Client.Subscription.Buffer` built from the `:owner`, `:ref`,
  `:max_buffer`, and `:overflow` options, pushes each later notification to it
  as `{:notification, method, params}`, closes it with `:complete` or
  `{:error, %Snodo.Error{}}` at the terminal response or a connection failure,
  and exits once the buffer is done. It handles `{:mcp_client_demand, ref, n}`
  messages by adding demand, and a `{:mcp_client_close, ref}` call by
  cancelling the stream on the server and replying `:ok`. It monitors the owner
  and cancels the stream when the owner exits. A JSON-RPC error response
  before the acknowledgement is returned as `{:error, %Snodo.Error{}}`.
  `Snodo.Client.listen/3` raises `ArgumentError` for a transport without
  `listen/3`.

  Failures of the connection itself are `%Snodo.Error{kind: :transport}`. Use
  `connection_error/2` (-32000) and `timeout_error/1` (-32001), the codes the
  official TypeScript SDK uses for the same client-side conditions.
  """

  alias Snodo.Error

  @type state :: term()

  @callback connect(init_arg :: term(), opts :: keyword()) :: {:ok, state()} | {:error, Error.t()}
  @callback request(state(), message :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, Error.t()}
  @callback listen(state(), message :: map(), opts :: keyword()) ::
              {:ok, accepted_filter :: map(), pid()} | {:error, Error.t()}
  @callback close(state()) :: :ok

  @optional_callbacks listen: 3

  @connection_closed -32_000
  @request_timeout -32_001

  @doc "The connection is closed, unreachable, or produced an unusable response."
  @spec connection_error(String.t(), term()) :: Error.t()
  def connection_error(message, cause) when is_binary(message) do
    %Error{code: @connection_closed, message: message, kind: :transport, cause: cause}
  end

  @doc """
  Progress kept moving the deadline of a request, and the response had not
  arrived `max_total_timeout` milliseconds after the request started.
  """
  @spec max_total_timeout_error(pos_integer()) :: Error.t()
  def max_total_timeout_error(max_total_timeout) do
    %Error{
      code: @request_timeout,
      message: "Maximum total timeout exceeded",
      kind: :transport,
      data: %{"maxTotalTimeoutMs" => max_total_timeout},
      cause: :max_total_timeout
    }
  end

  @doc "No response arrived within `timeout` milliseconds."
  @spec timeout_error(timeout()) :: Error.t()
  def timeout_error(timeout) do
    %Error{
      code: @request_timeout,
      message: "Request timed out",
      kind: :transport,
      data: %{"timeoutMs" => timeout},
      cause: :timeout
    }
  end
end
