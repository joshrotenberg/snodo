defmodule Snodo.Extensions.Tasks.Client do
  @moduledoc """
  Client helpers for the Tasks extension, built on `Snodo.Client`.

  Every function here takes a `Snodo.Client` and sends its requests with
  `Snodo.Client.request/4`, `Snodo.Client.call_tool/4`, and
  `Snodo.Client.listen/3`, so it works with any client those functions work
  with: `Snodo.Client.direct/2`, stdio, and Streamable HTTP. See "Transports"
  below for what Streamable HTTP does not carry yet.

      {:ok, client} = Snodo.Client.connect({:stdio, "my_server", []})

      case Snodo.Extensions.Tasks.Client.call_tool(client, "export", %{"id" => 7}) do
        {:task, status} -> Snodo.Extensions.Tasks.Client.await(client, status)
        {:ok, result} -> {:ok, result}
        {:error, error} -> {:error, error}
      end

      # or, in one call
      Snodo.Extensions.Tasks.Client.call_and_await(client, "export", %{"id" => 7})

  ## Negotiation

  The extension is negotiated per request: the client declares
  `extensions["io.modelcontextprotocol/tasks"]` in the request's client
  capabilities, and a server that serves Tasks may then answer a `tools/call`
  with a task. Each function here adds that declaration to the requests it
  sends, through the `:meta` option of `Snodo.Client.request/4`, on top of the
  client's own `:client_capabilities`. The client does not need to be built
  with it, and its other requests are unaffected: `Snodo.Client.call_tool/4`
  on the same client still runs a tool the server marks `:optional`
  synchronously.

  To declare the extension on every request instead, pass `capabilities/1` as
  the client's `:client_capabilities`. `server_supports?/1` reads whether the
  server advertises the extension.

  ## Outcomes

  `await/3` and `call_and_await/5` return the task's outcome:

    * `{:ok, result}` - the task completed. `result` is the final
      `CallToolResult` map, string keys, as `Snodo.Client.call_tool/4` would
      have returned it for a synchronous call. A result with
      `"isError" => true` is a tool that ran and reported its own failure.
    * `{:error, %Snodo.Error{}}` - the task failed, with the server's JSON-RPC
      error as `code`, `message`, and `data` and the failed
      `Snodo.Extensions.Tasks.Client.Status` in `cause` as
      `{:task_failed, status}`; or a request failed, or the wait timed out.
    * `{:cancelled, status}` - the task was cancelled.
    * `{:input_required, status}` - the task is waiting for input this call
      did not answer. See "Input" below.

  ## Waiting

  `await/3` polls `tasks/get` by default. Between polls it waits the task's
  `pollIntervalMs`, or `:poll_interval` when the server sent none, and never
  less than `:min_poll_interval`. With `listen: true` it opens a
  `subscriptions/listen` stream for the task instead and waits for
  `notifications/tasks` events, reading the status once with `tasks/get`
  after the stream is acknowledged so a change made before the stream opened
  is not missed. A stream that ends before the task does, as one from a source
  that sends only the current status, is followed by polling. A server
  without a subscription source refuses `subscriptions/listen` with -32601,
  which `await/3` returns.

  Either way the wait is bounded by `:timeout`, 60,000 ms unless set. At the
  limit `await/3` returns -32001 (`kind: :transport`) with `"taskId"` and
  `"timeoutMs"` in `data` and `{:timeout, status}` in `cause`, where `status`
  is the last status read. The task keeps running on the server; call
  `await/3` again to keep waiting, or `cancel/3`.

  ## Input

  A task that needs input reports `:input_required` with its outstanding
  requests in `input_requests`, keyed by the key `tasks/update` answers them
  under. `await/3` answers them according to `:input`:

    * `:handlers` (the default) - the client's `:input_handlers`, the same
      functions `Snodo.Client` answers `input_required` results with. An
      `elicitation/create` request goes to the `:form` or `:url` handler by
      its `mode` (`:form` when it has none), `sampling/createMessage` to
      `:sampling`, and `roots/list` to `:roots`. Each handler receives the
      request's `params` and returns `{:ok, response}`. When a request has no
      handler for its kind, no handler runs and `await/3` returns
      `{:input_required, status}`.
    * `:return` - returns `{:input_required, status}` at once.
    * a function of one argument - called with the status, its
      `input_requests` limited to the requests not answered yet during this
      wait, and returns `{:ok, responses}`, a map from key to response, or
      `{:error, reason}`.

  The responses are sent with `tasks/update` and the wait goes on. A handler
  or function that returns `{:error, reason}` or anything other than
  `{:ok, map}` stops the wait with -32603 (`kind: :execution`) and
  `cause: {:input_handler, key, reason, status}`; `key` is `nil` for the
  function form. To answer by hand, call `update/4` with the responses and
  then `await/3` again.

  ## Transports

  Over Streamable HTTP the server requires an `Mcp-Name` header that mirrors
  `params.taskId` on `tasks/get`, `tasks/update`, and `tasks/cancel`.
  `Snodo.Client`'s HTTP transport derives the headers it sends from the core
  protocol dialect, which does not know the extension's methods, so it does
  not send that header and the server answers -32020. A task-augmented
  `tools/call` and `subscriptions/listen` work over HTTP; the task methods,
  and therefore `await/3`, work over `Snodo.Client.direct/2` and stdio.
  """

  alias Snodo.Client.Subscription
  alias Snodo.Client.Transport
  alias Snodo.Error
  alias Snodo.Extensions.Tasks
  alias Snodo.Extensions.Tasks.Client.Status

  @typedoc "A task, by its `taskId` or by a status read earlier."
  @type task_ref :: String.t() | Status.t()

  @typedoc "How a task ended, or why a wait stopped. See \"Outcomes\" in the module doc."
  @type outcome ::
          {:ok, map()}
          | {:error, Error.t()}
          | {:cancelled, Status.t()}
          | {:input_required, Status.t()}

  @typedoc "The `:input` option of `await/3`."
  @type input ::
          :handlers
          | :return
          | (Status.t() -> {:ok, %{optional(String.t()) => map()}} | {:error, term()})

  @default_timeout 60_000
  @default_poll_interval 1_000
  @default_min_poll_interval 50
  @notification "notifications/tasks"

  @doc """
  Adds the Tasks extension to a client capabilities map.

  Pass the result as `:client_capabilities` to `Snodo.Client.direct/2` or
  `Snodo.Client.connect/2` to declare the extension on every request:

      Snodo.Client.direct(runtime,
        client_capabilities: Snodo.Extensions.Tasks.Client.capabilities()
      )

  The extension defines no settings, so its entry is `%{}`.
  """
  @spec capabilities(map()) :: map()
  def capabilities(capabilities \\ %{}) when is_map(capabilities) do
    extensions = Map.get(capabilities, "extensions", %{})
    Map.put(capabilities, "extensions", Map.put(extensions, Tasks.id(), %{}))
  end

  @doc """
  Reads whether the server advertises the Tasks extension.

  On a 2026-07-28 connection this requests `server/discover` and looks for
  the extension under `capabilities.extensions`. On an initialize-era
  connection it reads the capabilities `initialize` returned, which never
  carry the extension.
  """
  @spec server_supports?(Snodo.Client.t()) :: {:ok, boolean()} | {:error, Error.t()}
  def server_supports?(%Snodo.Client{session: %{server_capabilities: capabilities}}),
    do: {:ok, advertised?(capabilities)}

  def server_supports?(%Snodo.Client{} = client) do
    with {:ok, result} <- Snodo.Client.discover(client) do
      {:ok, advertised?(Map.get(result, "capabilities"))}
    end
  end

  @doc """
  Calls a tool, declaring the Tasks extension for the call.

  Returns `{:task, status}` when the server created a task for the call;
  `status` is usually `:working`. Otherwise the server ran the tool at once
  and the response is returned as `Snodo.Client.call_tool/4` returns it:
  `{:ok, result}`, `{:input_required, result}`, or `{:error, error}`. A tool
  the server runs only as a task (`:required`) answers -32021 to a request
  that does not declare the extension; this function always declares it.

  Options are those of `Snodo.Client.call_tool/4`. Entries in `:meta` win
  over the extension declaration.
  """
  @spec call_tool(Snodo.Client.t(), String.t() | map(), map(), keyword()) ::
          {:task, Status.t()} | Snodo.Client.response()
  def call_tool(%Snodo.Client{} = client, tool, arguments \\ %{}, opts \\ [])
      when is_map(arguments) and is_list(opts) do
    case Snodo.Client.call_tool(client, tool, arguments, declare(client, opts)) do
      {:ok, %{"resultType" => "task"} = result} ->
        with {:ok, status} <- decode(result), do: {:task, status}

      response ->
        response
    end
  end

  @doc """
  Calls a tool and, when the server answers with a task, waits for it.

  `call_opts` are the options of `call_tool/4`; `await_opts` those of
  `await/3`. A tool the server ran at once returns what `call_tool/4`
  returned, so `{:input_required, result}` here may be an ordinary
  multi round-trip result (a map) rather than a task status.
  """
  @spec call_and_await(Snodo.Client.t(), String.t() | map(), map(), keyword(), keyword()) ::
          outcome() | Snodo.Client.response()
  def call_and_await(
        %Snodo.Client{} = client,
        tool,
        arguments \\ %{},
        call_opts \\ [],
        await_opts \\ []
      ) do
    case call_tool(client, tool, arguments, call_opts) do
      {:task, status} -> await(client, status, await_opts)
      response -> response
    end
  end

  @doc """
  Requests `tasks/get` and decodes the task.

  An unknown task, or one in another authorization scope, is -32602. A
  result that is not a task is a -32000 transport error with the result in
  `cause`. Options are those of `Snodo.Client.request/4`.
  """
  @spec get(Snodo.Client.t(), task_ref(), keyword()) :: {:ok, Status.t()} | {:error, Error.t()}
  def get(%Snodo.Client{} = client, task, opts \\ []) when is_list(opts) do
    case Snodo.Client.request(
           client,
           "tasks/get",
           %{"taskId" => task_id(task)},
           declare(client, opts)
         ) do
      {:ok, result} -> decode(result)
      {:input_required, result} -> {:error, invalid_task(result)}
      {:error, %Error{}} = error -> error
    end
  end

  @doc """
  Requests `tasks/update` with input responses.

  `responses` maps each key of the status's `input_requests` to its
  response, for example an elicitation result
  `%{"action" => "accept", "content" => %{...}}`. The server ignores keys it
  is not waiting for. Options are those of `Snodo.Client.request/4`.
  """
  @spec update(Snodo.Client.t(), task_ref(), %{optional(String.t()) => map()}, keyword()) ::
          :ok | {:error, Error.t()}
  def update(%Snodo.Client{} = client, task, responses, opts \\ [])
      when is_map(responses) and is_list(opts) do
    params = %{"taskId" => task_id(task), "inputResponses" => responses}
    acknowledge(Snodo.Client.request(client, "tasks/update", params, declare(client, opts)))
  end

  @doc """
  Requests `tasks/cancel`.

  Cancelling a task that has already finished succeeds and changes nothing;
  read the status to see how it ended. Options are those of
  `Snodo.Client.request/4`.
  """
  @spec cancel(Snodo.Client.t(), task_ref(), keyword()) :: :ok | {:error, Error.t()}
  def cancel(%Snodo.Client{} = client, task, opts \\ []) when is_list(opts) do
    params = %{"taskId" => task_id(task)}
    acknowledge(Snodo.Client.request(client, "tasks/cancel", params, declare(client, opts)))
  end

  @doc """
  Waits for a task to finish and returns its outcome.

  The wait starts by reading the task with `tasks/get`, unless it is given a
  finished task's status, whose outcome it returns at once. See the module
  doc for the outcomes, the two ways of waiting, and input.

  Options:

    * `:timeout` - the most milliseconds to wait, or `:infinity`. Defaults to
      60,000.
    * `:listen` - when `true`, wait for `notifications/tasks` on a
      `subscriptions/listen` stream instead of polling. Defaults to `false`.
    * `:poll_interval` - milliseconds between polls when the task has no
      `pollIntervalMs`. Defaults to 1,000.
    * `:min_poll_interval` - the fewest milliseconds between polls, whatever
      the task's `pollIntervalMs`. Defaults to 50.
    * `:input` - `:handlers`, `:return`, or a function. Defaults to
      `:handlers`.
    * `:request_timeout` - the timeout of each request the wait sends.
      Defaults to the client's.
  """
  @spec await(Snodo.Client.t(), task_ref(), keyword()) :: outcome()
  def await(%Snodo.Client{} = client, task, opts \\ []) when is_list(opts) do
    state = wait_state!(client, task_id(task), opts)

    cond do
      # A finished task never changes.
      is_struct(task, Status) and Status.terminal?(task) ->
        outcome(task)

      state.listen? ->
        listen(state)

      true ->
        with {:ok, status} <- get(client, state.task_id, state.request_opts),
             do: poll(state, status)
    end
  end

  @doc """
  Returns the outcome of a finished task: `{:ok, result}` for `:completed`,
  `{:error, %Snodo.Error{}}` for `:failed`, and `{:cancelled, status}` for
  `:cancelled`.
  """
  @spec outcome(Status.t()) :: outcome()
  def outcome(%Status{status: :completed, result: result}), do: {:ok, result}

  def outcome(%Status{status: :failed, error: error} = status) do
    code = Map.fetch!(error, "code")

    {:error,
     %Error{
       code: code,
       message: Map.fetch!(error, "message"),
       data: Map.get(error, "data"),
       kind: error_kind(code),
       cause: {:task_failed, status}
     }}
  end

  def outcome(%Status{status: :cancelled} = status), do: {:cancelled, status}

  # Polling

  defp poll(state, status) do
    case observe(state, status) do
      {:done, outcome} -> outcome
      {:continue, state} -> poll_next(state, status)
    end
  end

  defp poll_next(state, status) do
    case remaining(state) do
      0 ->
        {:error, timeout_error(state, status)}

      remaining ->
        Process.sleep(min(interval(state, status), remaining))

        with {:ok, status} <- get(state.client, state.task_id, state.request_opts) do
          poll(state, status)
        end
    end
  end

  defp interval(state, %Status{poll_interval_ms: interval}) do
    max(interval || state.poll_interval, state.min_poll_interval)
  end

  # Listening

  defp listen(state) do
    listen_opts = declare(state.client, state.request_opts)
    filter = %{"taskIds" => [state.task_id]}

    with {:ok, subscription} <- Snodo.Client.listen(state.client, filter, listen_opts) do
      try do
        listen_from(%{state | subscription: subscription})
      after
        :ok = Subscription.close(subscription)
        flush(subscription.ref)
      end
    end
  end

  defp listen_from(%{subscription: subscription} = state) do
    if state.task_id in List.wrap(subscription.accepted["taskIds"]) do
      with {:ok, status} <- get(state.client, state.task_id, state.request_opts) do
        stream(state, status)
      end
    else
      {:error, Error.invalid_params("Unknown or inaccessible taskId")}
    end
  end

  defp stream(state, status) do
    case observe(state, status) do
      {:done, outcome} -> outcome
      {:continue, state} -> stream_next(state, status)
    end
  end

  defp stream_next(%{subscription: subscription, task_id: task_id} = state, status) do
    case Subscription.next(subscription, remaining(state)) do
      {:notification, @notification, %{"taskId" => ^task_id} = params} ->
        with {:ok, status} <- decode(params), do: stream(state, status)

      {:notification, _method, _params} ->
        stream_next(state, status)

      {:dropped, _count} ->
        with {:ok, status} <- get(state.client, task_id, state.request_opts) do
          stream(state, status)
        end

      {:closed, _reason} ->
        poll_next(state, status)

      {:error, :timeout} ->
        {:error, timeout_error(state, status)}
    end
  end

  # The demand of a timed-out `next/2` can deliver one more message after the
  # stream is closed.
  defp flush(ref) do
    receive do
      {:snodo_subscription, ^ref, _payload} -> flush(ref)
    after
      0 -> :ok
    end
  end

  # One status, from either way of waiting.

  defp observe(state, %Status{status: :input_required} = status) do
    pending = Map.drop(status.input_requests, MapSet.to_list(state.answered))

    if map_size(pending) == 0,
      do: {:continue, state},
      else: answer(state, status, pending)
  end

  defp observe(state, %Status{} = status) do
    if Status.terminal?(status),
      do: {:done, outcome(status)},
      else: {:continue, state}
  end

  defp answer(state, status, pending) do
    case responses(state, %{status | input_requests: pending}) do
      {:ok, responses} ->
        case update(state.client, state.task_id, responses, state.request_opts) do
          :ok ->
            answered = MapSet.union(state.answered, MapSet.new(Map.keys(responses)))
            {:continue, %{state | answered: answered}}

          {:error, %Error{}} = error ->
            {:done, error}
        end

      :return ->
        {:done, {:input_required, status}}

      {:error, %Error{}} = error ->
        {:done, error}
    end
  end

  defp responses(%{input: :return}, _status), do: :return

  defp responses(%{input: :handlers, client: client}, status) do
    case match_handlers(client.input_handlers, status.input_requests) do
      {:ok, calls} -> run_handlers(calls, status)
      :unhandled -> :return
    end
  end

  defp responses(%{input: fun}, status) when is_function(fun, 1) do
    case fun.(status) do
      {:ok, responses} when is_map(responses) -> {:ok, responses}
      {:error, reason} -> {:error, input_error(nil, reason, status)}
      other -> {:error, input_error(nil, {:invalid_return, other}, status)}
    end
  end

  defp match_handlers(handlers, requests) do
    Enum.reduce_while(requests, {:ok, []}, fn {key, request}, {:ok, calls} ->
      with kind when not is_nil(kind) <- input_kind(request),
           {:ok, handler} <- Map.fetch(handlers, kind),
           params when is_map(params) <- Map.get(request, "params", %{}) do
        {:cont, {:ok, [{key, handler, params} | calls]}}
      else
        _unhandled -> {:halt, :unhandled}
      end
    end)
  end

  defp run_handlers(calls, status) do
    calls
    |> Enum.sort_by(fn {key, _handler, _params} -> key end)
    |> Enum.reduce_while({:ok, %{}}, fn {key, handler, params}, {:ok, responses} ->
      case handler.(params) do
        {:ok, response} when is_map(response) ->
          {:cont, {:ok, Map.put(responses, key, response)}}

        {:error, reason} ->
          {:halt, {:error, input_error(key, reason, status)}}

        other ->
          {:halt, {:error, input_error(key, {:invalid_return, other}, status)}}
      end
    end)
  end

  defp input_kind(%{"method" => "elicitation/create"} = request) do
    case get_in(request, ["params", "mode"]) do
      mode when mode in [nil, "form"] -> :form
      "url" -> :url
      _other -> nil
    end
  end

  defp input_kind(%{"method" => "sampling/createMessage"}), do: :sampling
  defp input_kind(%{"method" => "roots/list"}), do: :roots
  defp input_kind(_request), do: nil

  # Options and shared helpers

  defp wait_state!(client, task_id, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    poll_interval = Keyword.get(opts, :poll_interval, @default_poll_interval)
    min_poll_interval = Keyword.get(opts, :min_poll_interval, @default_min_poll_interval)
    listen? = Keyword.get(opts, :listen, false)
    input = Keyword.get(opts, :input, :handlers)

    unless timeout == :infinity or (is_integer(timeout) and timeout > 0) do
      raise ArgumentError,
            ":timeout must be a positive integer or :infinity, got: #{inspect(timeout)}"
    end

    positive!(:poll_interval, poll_interval)
    positive!(:min_poll_interval, min_poll_interval)

    unless is_boolean(listen?) do
      raise ArgumentError, ":listen must be a boolean, got: #{inspect(listen?)}"
    end

    unless input in [:handlers, :return] or is_function(input, 1) do
      raise ArgumentError,
            ":input must be :handlers, :return, or a function of one argument, got: #{inspect(input)}"
    end

    request_opts =
      case Keyword.fetch(opts, :request_timeout) do
        {:ok, request_timeout} -> [timeout: request_timeout]
        :error -> []
      end

    %{
      client: client,
      task_id: task_id,
      timeout: timeout,
      deadline: deadline(timeout),
      poll_interval: poll_interval,
      min_poll_interval: min_poll_interval,
      listen?: listen?,
      input: input,
      request_opts: request_opts,
      answered: MapSet.new(),
      subscription: nil
    }
  end

  defp positive!(_option, value) when is_integer(value) and value > 0, do: :ok

  defp positive!(option, value) do
    raise ArgumentError, "#{inspect(option)} must be a positive integer, got: #{inspect(value)}"
  end

  defp deadline(:infinity), do: :infinity
  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp remaining(%{deadline: :infinity}), do: :infinity

  defp remaining(%{deadline: deadline}),
    do: max(deadline - System.monotonic_time(:millisecond), 0)

  # The declaration goes in the request's `_meta` through `:meta`, which wins
  # over the metadata the client builds from its own capabilities.
  defp declare(%Snodo.Client{dialect: dialect, client_capabilities: declared}, opts) do
    metadata = dialect.request_metadata(capabilities(declared))
    Keyword.update(opts, :meta, metadata, &Map.merge(metadata, &1))
  end

  defp acknowledge({:ok, _result}), do: :ok
  defp acknowledge({:input_required, result}), do: {:error, invalid_task(result)}
  defp acknowledge({:error, %Error{}} = error), do: error

  defp decode(map) do
    case Status.from_map(map) do
      {:ok, status} -> {:ok, status}
      {:error, _reason} -> {:error, invalid_task(map)}
    end
  end

  defp invalid_task(result),
    do: Transport.connection_error("The server sent an invalid task", result)

  defp task_id(%Status{task_id: task_id}), do: task_id
  defp task_id(task_id) when is_binary(task_id) and task_id != "", do: task_id

  defp task_id(other) do
    raise ArgumentError, "expected a taskId or a task status, got: #{inspect(other)}"
  end

  defp advertised?(%{"extensions" => %{} = extensions}),
    do: is_map(Map.get(extensions, Tasks.id()))

  defp advertised?(_capabilities), do: false

  defp timeout_error(state, status) do
    %Error{
      code: -32_001,
      message: "The task did not finish within the wait",
      kind: :transport,
      data: %{"taskId" => state.task_id, "timeoutMs" => state.timeout},
      cause: {:timeout, status}
    }
  end

  defp input_error(key, reason, status) do
    %Error{
      code: -32_603,
      message: "An input handler did not answer the task's input request",
      kind: :execution,
      cause: {:input_handler, key, reason, status}
    }
  end

  # The kinds `Snodo.Client` gives a JSON-RPC error response.
  defp error_kind(code) when code in [-32_700, -32_600], do: :json_rpc
  defp error_kind(code) when code in [-32_601, -32_602], do: :protocol
  defp error_kind(-32_603), do: :execution
  defp error_kind(_code), do: :protocol
end
