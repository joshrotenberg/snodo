defmodule Snodo.Client do
  @moduledoc """
  A client for MCP servers.

  `direct/2` dispatches to a runtime in the calling process. `connect/2` opens
  a stdio subprocess or a Streamable HTTP endpoint:

      {:ok, client} = Snodo.Client.direct(EchoServer.runtime())
      {:ok, client} = Snodo.Client.connect({:stdio, "elixir", ["echo_server.exs"]})
      {:ok, client} = Snodo.Client.connect({:http, "http://127.0.0.1:4000/mcp"})

      {:ok, [%{"name" => "echo"}]} = Snodo.Client.list_tools(client)

      {:ok, result} = Snodo.Client.call_tool(client, "echo", %{"text" => "hello"})
      result["content"]
      #=> [%{"type" => "text", "text" => "hello"}]

  The client builds each request, including the metadata the selected protocol
  dialect requires, and decodes the response into one of:

    * `{:ok, result}`: the JSON-RPC `result` object as the server sent it, with
      string keys. A `tools/call` result with `"isError" => true` is a
      successful response and arrives here.
    * `{:input_required, result}`: a multi round-trip request. Call again with
      `input_responses:` and, when the result carries a `"requestState"`,
      `request_state:`. See the interactive operations guide.
    * `{:error, %Snodo.Error{}}`: a JSON-RPC error or a transport failure. For a
      JSON-RPC error, `code`, `message`, and `data` are the server's, and
      `kind` is derived from the code: -32700 and -32600 are `:json_rpc`,
      -32601 and -32602 are `:protocol`, -32603 is `:execution`, and any other
      code is `:protocol`. Transport failures have `kind: :transport`: -32000
      when the connection is closed, unreachable, returns something that is
      not a JSON-RPC response, or returns a response over the transport's size
      limit, and -32001 when a request times out.

  Each request takes a fresh integer ID, so one client can be used from many
  processes at once. The client speaks the stateless `2026-07-28` protocol;
  initialize-era servers, which need a session handshake, are not supported.

  Pass `progress:` to a request to receive the server's progress
  notifications for it while it runs:

      Snodo.Client.call_tool(client, "index", %{}, progress: fn params ->
        IO.puts("\#{params["progress"]} of \#{params["total"]}")
      end)

  Install `input_handlers:` to answer a server's form and URL elicitation
  requests inside the call instead of receiving `{:input_required, result}`:

      {:ok, client} =
        Snodo.Client.connect({:http, url},
          input_handlers: %{form: &MyUI.form/1, url: &MyUI.url/1}
        )

  Open a `subscriptions/listen` stream with `listen/3` to receive change
  notifications as messages, or as a stream:

      {:ok, subscription} =
        Snodo.Client.listen(client, %{"resourceSubscriptions" => ["file:///notes.md"]})

      subscription
      |> Snodo.Client.Subscription.stream()
      |> Enum.each(fn
        {:notification, "notifications/resources/updated", %{"uri" => uri}} -> IO.puts(uri)
        other -> IO.inspect(other)
      end)
  """

  alias Snodo.Client.Deadline
  alias Snodo.Client.Direct
  alias Snodo.Client.HTTP
  alias Snodo.Client.Input
  alias Snodo.Client.Page
  alias Snodo.Client.Response
  alias Snodo.Client.Stdio
  alias Snodo.Client.Subscription
  alias Snodo.Client.Transport
  alias Snodo.Error
  alias Snodo.Protocol.Registry
  alias Snodo.Server.Runtime
  alias Snodo.Transport.ParamHeaders

  require Logger

  @type response :: {:ok, map()} | {:input_required, map()} | {:error, Error.t()}
  @type list_kind :: :tools | :resources | :resource_templates | :prompts

  @typedoc "A kind of input request a handler answers: one of the elicitation modes."
  @type input_kind :: :form | :url

  @typedoc """
  Answers one input request. Receives the request's `params` map and returns
  the response the server expects, or the reason the request was not answered.
  """
  @type input_handler :: (map() -> {:ok, map()} | {:error, term()})

  @typedoc "The `:input_handlers` option: at most one handler per kind."
  @type input_handlers :: %{optional(input_kind()) => input_handler()}
  @type target ::
          {:stdio, String.t(), [String.t()]}
          | {:http, String.t()}
          | {module(), term()}
  @type t :: %__MODULE__{
          transport: {module(), Transport.state()},
          protocol: String.t(),
          dialect: module(),
          client_capabilities: map(),
          client_info: map(),
          timeout: timeout(),
          max_pages: pos_integer(),
          input_handlers: input_handlers(),
          max_input_rounds: pos_integer()
        }

  @default_max_input_rounds 10
  @default_max_buffer 100
  @overflow_policies [:drop_oldest, :drop_newest]

  @enforce_keys [:transport, :protocol, :dialect]
  defstruct [
    :transport,
    :protocol,
    :dialect,
    client_capabilities: %{},
    client_info: %{},
    timeout: 30_000,
    max_pages: 1_000,
    input_handlers: %{},
    max_input_rounds: @default_max_input_rounds
  ]

  @remote_dialects [Snodo.Protocol.V2026_07_28]
  @version Mix.Project.config()[:version]

  # The pause before retrying a result that carries only a requestState, which
  # nothing else slows down. The official TypeScript client paces such a round
  # the same way.
  @state_only_pacing_ms 250

  @list_operations %{
    tools: {"tools/list", "tools"},
    resources: {"resources/list", "resources"},
    resource_templates: {"resources/templates/list", "resourceTemplates"},
    prompts: {"prompts/list", "prompts"}
  }
  @list_kinds Map.keys(@list_operations)

  @doc """
  Builds a client that dispatches to `runtime` in the calling process.

  Options:

    * `:protocol` - the protocol version to speak. Defaults to the first
      stateless-era version the runtime enables. Initialize-era versions need
      a session, which a direct client does not hold, so they are refused.
    * `:client_capabilities` - the capabilities sent with every request, for
      example `%{"elicitation" => %{"form" => %{}}}`. Defaults to `%{}`. The
      capabilities the installed `:input_handlers` imply are added to it.
    * `:input_handlers` - functions that answer the input requests a server
      embeds in an `input_required` result, as a map from request kind to a
      function of one argument. The kinds are `:form` and `:url`, the two
      elicitation modes; each adds its capability under `"elicitation"`. A
      handler receives the request's `params` map (`"mode"`, `"message"`,
      and `"requestedSchema"` or `"url"`) and returns `{:ok, response}`,
      where `response` is the elicitation result (`"action"` of `"accept"`,
      `"decline"`, or `"cancel"`, with `"content"` for an accepted form), or
      `{:error, reason}`. Defaults to `%{}`, which leaves `input_required`
      results to the caller. See `request/4` for the retry loop.
    * `:max_input_rounds` - the most `input_required` results the client
      answers for one call before failing it. Defaults to 10.
    * `:client_info` - the `Implementation` sent as
      `io.modelcontextprotocol/clientInfo` with every request: a map with
      string `"name"` and `"version"` and, optionally, `"title"`,
      `"description"`, `"websiteUrl"`, and `"icons"`. Defaults to
      `%{"name" => "snodo", "version" => <this library's version>}`.
    * `:auth` - the value handlers and authorization policies read as
      `context.auth`, as a transport would supply it after authenticating.
    * `:max_pages` - the most pages `list_tools/1` and the other list
      functions request before returning an error. Defaults to 1,000.
  """
  @spec direct(Runtime.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def direct(%Runtime{} = runtime, opts \\ []) when is_list(opts) do
    with {:ok, version} <- select_protocol(runtime, Keyword.get(opts, :protocol)),
         {:ok, dialect} <- Registry.fetch(runtime.protocol_registry, version),
         :ok <- require_stateless(dialect) do
      open(Direct, runtime, dialect, opts)
    end
  end

  @doc """
  Connects to a server in another process or on the network.

  Targets:

    * `{:stdio, command, args}` - runs `command` and speaks newline-delimited
      JSON-RPC over its stdin and stdout. See `Snodo.Client.Stdio` for `:env`
      and `:cd`. The connection closes when the calling process exits.
    * `{:http, url}` - posts each request to a Streamable HTTP endpoint. See
      `Snodo.Client.HTTP` for `:headers`, `:token_provider` (a
      `Snodo.Client.TokenProvider` that supplies and refreshes the bearer
      token), `:ssl`, `:connect_timeout`, and `:max_response_bytes`.
    * `{module, init_arg}` - any `Snodo.Client.Transport`.

  Options for every target:

    * `:protocol` - defaults to `"2026-07-28"`, the only supported version.
    * `:client_capabilities`, `:client_info`, `:max_pages`,
      `:input_handlers`, and `:max_input_rounds` - as for `direct/2`.
    * `:timeout` - the default request timeout in milliseconds, 30,000 unless
      set. Each request can override it with `timeout:`.
  """
  @spec connect(target(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def connect(target, opts \\ [])

  def connect({:stdio, command, args}, opts) when is_binary(command) and is_list(args),
    do: connect({Stdio, {command, args}}, opts)

  def connect({:http, url}, opts) when is_binary(url), do: connect({HTTP, url}, opts)

  def connect({module, init_arg}, opts) when is_atom(module) and is_list(opts) do
    unless Code.ensure_loaded?(module) and function_exported?(module, :request, 3) do
      raise ArgumentError,
            "expected {:stdio, command, args}, {:http, url}, or {transport_module, init_arg}, " <>
              "got a tuple starting with #{inspect(module)}"
    end

    with {:ok, dialect} <- remote_dialect(Keyword.get(opts, :protocol)) do
      open(module, init_arg, dialect, opts)
    end
  end

  @doc "Closes the client's connection. Closing an in-process client does nothing."
  @spec close(t()) :: :ok
  def close(%__MODULE__{transport: {module, state}}), do: module.close(state)

  @doc "Requests `server/discover`."
  @spec discover(t()) :: response()
  def discover(%__MODULE__{} = client), do: request(client, "server/discover")

  @doc """
  Lists every tool, following `nextCursor` to the last page.

  The list functions return a -32000 transport error when the server repeats a
  cursor, or when the last of the client's `:max_pages` pages still has a
  `nextCursor`.

  Over HTTP, a tool whose input schema has an invalid `x-mcp-header`
  annotation is left out and a warning is logged, as 2026-07-28 requires.
  """
  @spec list_tools(t()) :: {:ok, [map()]} | {:error, Error.t()}
  def list_tools(%__MODULE__{} = client), do: list_all(client, :tools)

  @doc "Lists every direct resource, following `nextCursor` until the last page."
  @spec list_resources(t()) :: {:ok, [map()]} | {:error, Error.t()}
  def list_resources(%__MODULE__{} = client), do: list_all(client, :resources)

  @doc "Lists every resource template, following `nextCursor` until the last page."
  @spec list_resource_templates(t()) :: {:ok, [map()]} | {:error, Error.t()}
  def list_resource_templates(%__MODULE__{} = client), do: list_all(client, :resource_templates)

  @doc "Lists every prompt, following `nextCursor` until the last page."
  @spec list_prompts(t()) :: {:ok, [map()]} | {:error, Error.t()}
  def list_prompts(%__MODULE__{} = client), do: list_all(client, :prompts)

  @doc """
  Requests one page of a list operation.

  `kind` is one of `:tools`, `:resources`, `:resource_templates`, or
  `:prompts`. Pass the previous page's `next_cursor` to continue.
  """
  @spec list_page(t(), list_kind(), String.t() | nil) :: {:ok, Page.t()} | {:error, Error.t()}
  def list_page(%__MODULE__{} = client, kind, cursor \\ nil)
      when kind in @list_kinds and (is_binary(cursor) or is_nil(cursor)) do
    {method, key} = Map.fetch!(@list_operations, kind)
    params = if cursor, do: %{"cursor" => cursor}, else: %{}

    case request(client, method, params) do
      {:ok, result} ->
        {:ok,
         %Page{
           items: usable(client, kind, Map.get(result, key, [])),
           next_cursor: Map.get(result, "nextCursor"),
           result: result
         }}

      {:error, %Error{}} = error ->
        error
    end
  end

  @doc """
  Calls a tool, by name or with its definition from `list_tools/1`.

  Options are those of `request/4`. A result with `"isError" => true` is
  returned as `{:ok, result}`: the tool ran and reported its own failure.

  Over HTTP, arguments whose input schema property carries `x-mcp-header`
  are also sent as `Mcp-Param-*` headers, which needs the tool's
  `inputSchema`. Pass the definition map to send them on the first request.
  Called by name, a tool that requires them is refused with -32020; the
  client then lists the tools and retries once with the definition.
  """
  @spec call_tool(t(), String.t() | map(), map(), keyword()) :: response()
  def call_tool(client, tool, arguments \\ %{}, opts \\ [])

  def call_tool(%__MODULE__{} = client, %{"name" => name} = tool, arguments, opts)
      when is_binary(name) and is_map(arguments) do
    request(
      client,
      "tools/call",
      %{"name" => name, "arguments" => arguments},
      Keyword.put(opts, :tool, tool)
    )
  end

  def call_tool(%__MODULE__{} = client, name, arguments, opts)
      when is_binary(name) and is_map(arguments) do
    case request(client, "tools/call", %{"name" => name, "arguments" => arguments}, opts) do
      {:error, %Error{code: -32_020}} = error ->
        retry_with_definition(client, name, arguments, opts, error)

      response ->
        response
    end
  end

  @doc "Reads a resource by exact URI. Options are those of `request/4`."
  @spec read_resource(t(), String.t(), keyword()) :: response()
  def read_resource(%__MODULE__{} = client, uri, opts \\ []) when is_binary(uri) do
    request(client, "resources/read", %{"uri" => uri}, opts)
  end

  @doc "Gets a rendered prompt. Options are those of `request/4`."
  @spec get_prompt(t(), String.t(), map(), keyword()) :: response()
  def get_prompt(%__MODULE__{} = client, name, arguments \\ %{}, opts \\ [])
      when is_binary(name) and is_map(arguments) do
    request(client, "prompts/get", %{"name" => name, "arguments" => arguments}, opts)
  end

  @doc """
  Sends any request method with the given params.

  Use it for methods without a dedicated function, such as
  `completion/complete` or a negotiated extension's methods. The dialect's
  request metadata is merged under `params["_meta"]`; keys already present in
  `params["_meta"]` win.

  Options:

    * `:input_responses` - answers to a previous `{:input_required, result}`,
      keyed by the IDs in its `"inputRequests"`. Sent as `inputResponses`.
    * `:request_state` - the `"requestState"` of a previous
      `{:input_required, result}`. Sent as `requestState`.
    * `:meta` - extra `_meta` entries. These win over the dialect's metadata
      and over `params["_meta"]`.
    * `:progress` - a function of one argument, or a pid, to receive the
      server's progress notifications for this request. The client sends the
      request ID as `_meta.progressToken`; a `"progressToken"` in `:meta` or
      `params["_meta"]` alongside `:progress` raises `ArgumentError`. A
      function is called in the calling process with each notification's
      `params` map (`"progressToken"`, `"progress"`, and, when the server sent
      them, `"total"` and `"message"`) before the request returns. A pid is
      sent `{:snodo_progress, params}`.
    * `:reset_timeout_on_progress` - when `true`, each progress notification
      restarts `:timeout`. Defaults to `false`. Has no effect without
      `:progress`, or on a direct client, which has no timeout.
    * `:max_total_timeout` - with `:reset_timeout_on_progress`, the most
      milliseconds a request may run, counted from when it was sent. Defaults
      to 600,000. A request stopped by this limit returns -32001 with the
      message "Maximum total timeout exceeded" and
      `data: %{"maxTotalTimeoutMs" => limit}`.
    * `:timeout` - overrides the client's request timeout.
    * `:answer_input` - when `false`, an `input_required` result is returned
      as `{:input_required, result}` even though the client has
      `:input_handlers`. Defaults to `true`.
    * `:max_input_rounds` - overrides the client's round limit for this
      request.

  With `:input_handlers` installed, an `input_required` result is answered
  in the calling process. Every entry of `"inputRequests"` is first matched
  to the handler for its kind and checked for the `params` that kind
  documents; only when all of them pass do the handlers run, one request at
  a time in the sort order of the request IDs (strings, so `"10"` sorts
  before `"2"`). The request is then sent again, on a fresh ID, with the
  responses as `inputResponses` and the result's `"requestState"`
  unchanged. That repeats until the server returns a complete result or
  `:max_input_rounds` results have been answered. A result that carries only
  a `"requestState"` is sent again with it after 250 milliseconds and counts
  as a round. Each round has its own `:timeout`, and `:progress` is delivered
  for every round. The loop stops with an error whose `cause` ends with the
  last `input_required` result, so the caller can finish the flow by hand:

    * -32602 (`kind: :protocol`, `cause: {:no_input_handler, kind, result}`)
      for a request of a kind with no handler; `kind` is the method string
      for a method the client does not know, and `nil` for an entry without
      one. No handler has run.
    * -32603 (`kind: :execution`, `cause: {:input_handler, id, reason, result}`)
      when a handler returned `{:error, reason}`, a value other than
      `{:ok, response}` (`reason` is `{:invalid_return, value}`), or a
      response without a valid `"action"` (`{:invalid_response, response}`).
      An exception raised by a handler propagates to the caller.
    * -32000 (`kind: :transport`, `data: %{"maxInputRounds" => limit}`,
      `cause: {:max_input_rounds, result}`) at the round limit.
    * -32000 (`kind: :transport`, `cause: result`) for a malformed result: one
      with nothing to answer and no `"requestState"`, or an input request
      whose `params` is not an object or lacks the keys of its kind
      (`"message"` and `"requestedSchema"` for a form, `"message"` and
      `"url"` for a URL). No handler has run.

  `subscriptions/listen` raises `ArgumentError`: its response is a stream,
  which `listen/3` opens.
  """
  @spec request(t(), String.t(), map(), keyword()) :: response()
  def request(%__MODULE__{} = client, method, params \\ %{}, opts \\ [])
      when is_binary(method) and is_map(params) and is_list(opts) do
    if method == "subscriptions/listen" do
      raise ArgumentError, "subscriptions/listen is a stream; open it with Snodo.Client.listen/3"
    end

    send_request(client, method, params, opts, input_plan(client, opts), 0)
  end

  @doc """
  Opens a `subscriptions/listen` stream and returns its handle.

  `notifications` is the requested filter, sent as `params["notifications"]`
  as given: the core keys `"toolsListChanged"`, `"promptsListChanged"`,
  `"resourcesListChanged"`, and `"resourceSubscriptions"` (a list of URIs),
  and any key a negotiated extension defines, such as the Tasks extension's
  `"taskIds"`. The server validates it and answers -32602 for an invalid one.

  Returns `{:ok, subscription}` once the server's
  `notifications/subscriptions/acknowledged` arrives; `subscription.accepted`
  is the filter the server agreed to, which may be a subset of the request.
  Returns `{:error, %Snodo.Error{}}` for a JSON-RPC error response (for
  example -32601 from a server without a subscription source), for a stream
  the server ends before acknowledging it, and for a transport failure; -32001
  when no acknowledgement arrives within `:timeout`.

  The calling process owns the subscription: events reach it as
  `{:snodo_subscription, ref, payload}` messages once it asks for them with
  `Snodo.Client.Subscription.demand/2`, `next/2`, or `stream/1`, and the
  stream is cancelled when it exits. See `Snodo.Client.Subscription` for the
  payloads and the buffer.

  Options:

    * `:max_buffer` - the most events held for the owner before the overflow
      policy applies. Defaults to 100.
    * `:overflow` - `:drop_oldest` (the default) or `:drop_newest`.
    * `:timeout` - overrides the client's request timeout for the wait for
      the acknowledgement. A direct client has no timeout.
    * `:meta` - extra `_meta` entries, as for `request/4`.

  Raises `ArgumentError` for a custom transport without `listen/3`.
  """
  @spec listen(t(), map(), keyword()) :: {:ok, Subscription.t()} | {:error, Error.t()}
  def listen(%__MODULE__{transport: {module, state}} = client, notifications, opts \\ [])
      when is_map(notifications) and is_list(opts) do
    unless function_exported?(module, :listen, 3) do
      raise ArgumentError, "#{inspect(module)} does not implement listen/3"
    end

    max_buffer = Keyword.get(opts, :max_buffer, @default_max_buffer)
    overflow = Keyword.get(opts, :overflow, :drop_oldest)

    unless is_integer(max_buffer) and max_buffer > 0 do
      raise ArgumentError, ":max_buffer must be a positive integer, got: #{inspect(max_buffer)}"
    end

    unless overflow in @overflow_policies do
      raise ArgumentError,
            ":overflow must be one of #{inspect(@overflow_policies)}, got: #{inspect(overflow)}"
    end

    id = System.unique_integer([:positive, :monotonic])
    ref = make_ref()

    raw = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "subscriptions/listen",
      "params" => build_params(client, %{"notifications" => notifications}, opts)
    }

    transport_opts = [
      dialect: client.dialect,
      timeout: Keyword.get(opts, :timeout, client.timeout),
      owner: self(),
      ref: ref,
      max_buffer: max_buffer,
      overflow: overflow
    ]

    case module.listen(state, raw, transport_opts) do
      {:ok, accepted, pid} when is_map(accepted) and is_pid(pid) ->
        {:ok, %Subscription{ref: ref, id: id, accepted: accepted, owner: self(), pid: pid}}

      {:error, %Error{}} = error ->
        error
    end
  end

  defp send_request(client, method, params, opts, plan, round) do
    id = System.unique_integer([:positive, :monotonic])
    progress = progress_callback(Keyword.get(opts, :progress))

    raw = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => client |> build_params(params, opts) |> put_progress_token(progress, id)
    }

    {module, state} = client.transport

    transport_opts =
      [dialect: client.dialect, timeout: Keyword.get(opts, :timeout, client.timeout)] ++
        Keyword.take(opts, [:tool]) ++ progress_options(progress, opts)

    case module.request(state, raw, transport_opts) do
      {:ok, response} ->
        response
        |> Response.decode()
        |> answer_input(client, method, params, opts, plan, round)

      {:error, %Error{}} = error ->
        error
    end
  end

  # `plan` is nil when the client has no handlers or the call opted out; the
  # result then reaches the caller as it is.
  defp answer_input({:input_required, result}, client, method, params, opts, %{} = plan, round) do
    with :ok <- check_rounds(plan, round, result),
         {:ok, responses} <- Input.answer(plan.handlers, result) do
      if map_size(responses) == 0, do: Process.sleep(@state_only_pacing_ms)

      opts =
        opts
        |> Keyword.drop([:input_responses, :request_state])
        |> put_present_option(:input_responses, responses)
        |> put_present_option(:request_state, Map.get(result, "requestState"))

      send_request(client, method, params, opts, plan, round + 1)
    end
  end

  defp answer_input(response, _client, _method, _params, _opts, _plan, _round), do: response

  defp check_rounds(%{max_rounds: limit}, round, _result) when round < limit, do: :ok

  defp check_rounds(%{max_rounds: limit}, _round, result),
    do: {:error, Input.rounds_exceeded(limit, result)}

  defp input_plan(%__MODULE__{} = client, opts) do
    answer? = Keyword.get(opts, :answer_input, true)
    max_rounds = max_input_rounds!(Keyword.get(opts, :max_input_rounds, client.max_input_rounds))

    unless is_boolean(answer?) do
      raise ArgumentError, ":answer_input must be a boolean, got: #{inspect(answer?)}"
    end

    if answer? and map_size(client.input_handlers) > 0,
      do: %{handlers: client.input_handlers, max_rounds: max_rounds},
      else: nil
  end

  defp max_input_rounds!(rounds) when is_integer(rounds) and rounds > 0, do: rounds

  defp max_input_rounds!(rounds) do
    raise ArgumentError, ":max_input_rounds must be a positive integer, got: #{inspect(rounds)}"
  end

  defp put_present_option(opts, _key, nil), do: opts
  defp put_present_option(opts, _key, empty) when empty == %{}, do: opts
  defp put_present_option(opts, key, value), do: Keyword.put(opts, key, value)

  defp open(module, init_arg, dialect, opts) do
    capabilities = Keyword.get(opts, :client_capabilities, %{})
    timeout = Keyword.get(opts, :timeout, 30_000)
    max_pages = Keyword.get(opts, :max_pages, 1_000)
    handlers = opts |> Keyword.get(:input_handlers, %{}) |> Input.validate_handlers!()

    max_input_rounds =
      max_input_rounds!(Keyword.get(opts, :max_input_rounds, @default_max_input_rounds))

    unless is_map(capabilities) do
      raise ArgumentError, ":client_capabilities must be a map, got: #{inspect(capabilities)}"
    end

    unless timeout == :infinity or (is_integer(timeout) and timeout > 0) do
      raise ArgumentError,
            ":timeout must be a positive integer or :infinity, got: #{inspect(timeout)}"
    end

    unless is_integer(max_pages) and max_pages > 0 do
      raise ArgumentError, ":max_pages must be a positive integer, got: #{inspect(max_pages)}"
    end

    client_info = Keyword.get_lazy(opts, :client_info, &default_client_info/0)
    validate_client_info!(client_info)

    with {:ok, state} <- module.connect(init_arg, opts) do
      {:ok,
       %__MODULE__{
         transport: {module, state},
         protocol: dialect.version(),
         dialect: dialect,
         client_capabilities:
           Input.merge_capabilities(Input.capabilities(handlers), capabilities),
         client_info: client_info,
         timeout: timeout,
         max_pages: max_pages,
         input_handlers: handlers,
         max_input_rounds: max_input_rounds
       }}
    end
  end

  defp default_client_info, do: %{"name" => "snodo", "version" => @version}

  defp validate_client_info!(%{"name" => name, "version" => version} = info)
       when is_binary(name) and name != "" and is_binary(version) do
    unless Enum.all?(Map.keys(info), &is_binary/1) do
      raise ArgumentError, ":client_info must have string keys, got: #{inspect(info)}"
    end
  end

  defp validate_client_info!(info) do
    raise ArgumentError,
          ":client_info must be a map with string \"name\" and \"version\", got: #{inspect(info)}"
  end

  defp remote_dialect(nil), do: {:ok, hd(@remote_dialects)}

  defp remote_dialect(version) when is_binary(version) do
    case Enum.find(@remote_dialects, &(&1.version() == version)) do
      nil ->
        {:error,
         Error.invalid_params("Snodo.Client does not support protocol #{version}", %{
           "requested" => version,
           "supported" => Enum.map(@remote_dialects, & &1.version())
         })}

      dialect ->
        {:ok, dialect}
    end
  end

  defp remote_dialect(version) do
    raise ArgumentError, ":protocol must be a version string, got: #{inspect(version)}"
  end

  defp select_protocol(runtime, nil) do
    case Registry.versions(runtime.protocol_registry, era: :stateless) do
      [version | _rest] ->
        {:ok, version}

      [] ->
        {:error,
         Error.invalid_params(
           "The runtime enables no stateless protocol version for a direct client",
           %{"enabled" => Registry.versions(runtime.protocol_registry)}
         )}
    end
  end

  defp select_protocol(_runtime, version) when is_binary(version), do: {:ok, version}

  defp select_protocol(_runtime, version) do
    raise ArgumentError, ":protocol must be a version string, got: #{inspect(version)}"
  end

  defp require_stateless(dialect) do
    if dialect.era() == :stateless do
      :ok
    else
      {:error,
       Error.invalid_params(
         "Protocol #{dialect.version()} needs a session, which a direct client does not hold",
         %{"requested" => dialect.version()}
       )}
    end
  end

  defp build_params(client, params, opts) do
    metadata =
      client.dialect.request_metadata(client.client_capabilities)
      |> put_client_info(client)
      |> Map.merge(Map.get(params, "_meta", %{}))
      |> Map.merge(Keyword.get(opts, :meta, %{}))

    params
    |> put_present("inputResponses", Keyword.get(opts, :input_responses))
    |> put_present("requestState", Keyword.get(opts, :request_state))
    |> Map.put("_meta", metadata)
  end

  # Only stateless dialects carry client info on every request.
  defp put_client_info(metadata, %__MODULE__{dialect: dialect, client_info: info}) do
    if function_exported?(dialect, :client_info_key, 0),
      do: Map.put(metadata, dialect.client_info_key(), info),
      else: metadata
  end

  defp progress_callback(nil), do: nil
  defp progress_callback(pid) when is_pid(pid), do: &send(pid, {:snodo_progress, &1})
  defp progress_callback(fun) when is_function(fun, 1), do: fun

  defp progress_callback(other) do
    raise ArgumentError,
          ":progress must be a function of one argument or a pid, got: #{inspect(other)}"
  end

  defp put_progress_token(params, nil, _id), do: params

  defp put_progress_token(%{"_meta" => metadata} = params, _progress, id) do
    if Map.has_key?(metadata, "progressToken") do
      raise ArgumentError,
            ":progress sets the progressToken; do not also pass one in :meta or params"
    end

    put_in(params, ["_meta", "progressToken"], id)
  end

  defp progress_options(nil, _opts), do: []

  defp progress_options(progress, opts) do
    reset? = Keyword.get(opts, :reset_timeout_on_progress, false)
    max_total = Keyword.get(opts, :max_total_timeout, Deadline.default_max_total_timeout())

    unless is_boolean(reset?) do
      raise ArgumentError, ":reset_timeout_on_progress must be a boolean, got: #{inspect(reset?)}"
    end

    unless is_integer(max_total) and max_total > 0 do
      raise ArgumentError,
            ":max_total_timeout must be a positive integer, got: #{inspect(max_total)}"
    end

    [on_progress: progress, reset_timeout_on_progress: reset?, max_total_timeout: max_total]
  end

  defp put_present(params, _key, nil), do: params
  defp put_present(params, key, value), do: Map.put(params, key, value)

  defp retry_with_definition(
         %__MODULE__{transport: {HTTP, _state}} = client,
         name,
         arguments,
         opts,
         error
       ) do
    with {:ok, tools} <- list_tools(client),
         %{"inputSchema" => schema} = tool <- Enum.find(tools, &(&1["name"] == name)),
         {:ok, [_annotation | _others]} <- ParamHeaders.annotations(schema) do
      call_tool(client, tool, arguments, opts)
    else
      _no_headers_to_add -> error
    end
  end

  defp retry_with_definition(_client, _name, _arguments, _opts, error), do: error

  # Only Streamable HTTP mirrors `x-mcp-header` arguments, so only there does an
  # invalid annotation make a tool unusable.
  defp usable(%__MODULE__{transport: {HTTP, _state}}, :tools, tools) do
    Enum.filter(tools, fn tool ->
      case ParamHeaders.annotations(Map.get(tool, "inputSchema", %{})) do
        {:ok, _annotations} ->
          true

        {:error, reason} ->
          Logger.warning("Ignoring tool #{inspect(tool["name"])}: #{reason}")
          false
      end
    end)
  end

  defp usable(_client, _kind, items), do: items

  defp list_all(client, kind), do: collect_pages(client, kind, nil, %{}, [])

  # A remote server can hand back a cursor it already issued, or a new cursor
  # on every page; following either would never terminate. `seen` holds the
  # cursor of every page after the first.
  defp collect_pages(client, kind, cursor, seen, pages) do
    with {:ok, %Page{items: items, next_cursor: next}} <- list_page(client, kind, cursor) do
      pages = [items | pages]

      cond do
        is_nil(next) ->
          {:ok, pages |> Enum.reverse() |> Enum.concat()}

        Map.has_key?(seen, next) ->
          {:error,
           Transport.connection_error("The server repeated a pagination cursor", %{
             kind: kind,
             cursor: next
           })}

        map_size(seen) + 1 >= client.max_pages ->
          {:error,
           Transport.connection_error(
             "The server sent more than #{client.max_pages} pages",
             %{kind: kind, max_pages: client.max_pages}
           )}

        true ->
          collect_pages(client, kind, next, Map.put(seen, next, true), pages)
      end
    end
  end
end
