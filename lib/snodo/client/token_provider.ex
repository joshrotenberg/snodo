defmodule Snodo.Client.TokenProvider do
  @moduledoc """
  Behaviour for the bearer tokens `Snodo.Client.HTTP` sends.

  A provider is passed to `Snodo.Client.connect/2` as
  `token_provider: {module, state}`. The transport calls it in the process
  that makes the request:

    * `token/2` before every request, including the request that opens a
      `Snodo.Client.listen/3` stream. `{:ok, token}` sends
      `Authorization: Bearer <token>`; `{:ok, nil}` sends the request without
      one, which is how a client learns the server's challenge on its first
      request.
    * `refresh/3` after a `401`, and after a `403` whose challenge is
      `insufficient_scope`. It receives the `Snodo.Client.Challenge` from the
      response (the `Bearer` challenge, or the first challenge of another
      scheme, or `nil` when the response has none) and a context with the
      status and the token that was refused. The provider obtains a new
      token, by refreshing, by starting an authorization flow, or by asking
      for more scope, and the transport sends the request once more with it.
      A second `401` or `403` returns a -32000 transport error with
      `cause: {:unauthorized, status, challenge}`.

  Both callbacks return `{:error, %Snodo.Error{}}` to fail the request with
  that error. Any other return raises `ArgumentError` in the caller. A token
  must be a string without CR, LF, or NUL; the transport refuses one that is
  not, without including it in the error.

  The transport's `:timeout` applies to each HTTP attempt. A provider call
  runs before an attempt and is not bounded by it, so a provider that
  blocks, for example while a user authorizes in a browser, lengthens the
  request by that long. A provider that talks to another process returns
  an error, rather than exiting, when that process is not running.

  The context is a map with `:url`, the endpoint the client connected to,
  and, for `refresh/3`, `:status` and `:token`. A provider that keeps state
  (a token cache, a refresh token, a pending authorization) typically hands
  the transport a pid or a registered name and does its work in that
  process, so several requesting processes share one token and one flow.
  `snodo_oauth` supplies `Snodo.OAuth.Client`, which implements the MCP
  authorization flows on top of this behaviour.

  A token is a credential: a provider must not log it or put it in an error
  message.
  """

  alias Snodo.Client.Challenge
  alias Snodo.Error

  @typedoc "Whatever the provider handed the transport, usually a pid or a name."
  @type state :: term()

  @typedoc """
  What the transport knows when it calls the provider: the endpoint URL and,
  for `refresh/3`, the response status and the refused token (`nil` when
  the request was sent without one).
  """
  @type context :: %{
          required(:url) => String.t(),
          optional(:status) => 401 | 403,
          optional(:token) => String.t() | nil
        }

  @doc """
  Returns the token for the next request, `{:ok, nil}` to send it without
  one, or `{:error, error}` to fail it. Called before every request and
  before opening a `subscriptions/listen` stream.
  """
  @callback token(state(), context()) :: {:ok, String.t() | nil} | {:error, Error.t()}

  @doc """
  Returns a new token after the server refused the request with a `401`,
  or with a `403` `insufficient_scope` challenge. `challenge` is the parsed
  challenge, or `nil` when the response had none; `context` carries the
  status and the refused token. The transport sends the request once more
  with the token returned.
  """
  @callback refresh(state(), Challenge.t() | nil, context()) ::
              {:ok, String.t()} | {:error, Error.t()}
end
