defmodule Snodo.Test.Assertions do
  @moduledoc """
  ExUnit assertions for testing an MCP server in process.

  Import the module in a test case and run requests with a direct client from
  `client!/2` or `client_as/3`, or with `Snodo.Test.dispatch/2`:

      defmodule MyServerTest do
        use ExUnit.Case, async: true

        import Snodo.Test.Assertions

        test "greets" do
          client = client!(MyServer.runtime())

          result = assert_tool_ok(Snodo.Client.call_tool(client, "greet", %{"name" => "Ada"}))
          assert [%{"text" => "Hello, Ada!"}] = result["content"]
        end
      end

  Every assertion returns the value it matched, so a test can go on to match
  its fields. A failed assertion raises `ExUnit.AssertionError` with the
  protocol error's code, message, and data, or the `isError` result's
  content, in its message.

  ## Responses

  The assertions accept a response in any of these forms:

    * what `Snodo.Client` returns: `{:ok, result}`, `{:input_required,
      result}`, or `{:error, %Snodo.Error{}}`;
    * what `Snodo.Test.dispatch/2` returns: `{:ok, response}` with the
      JSON-RPC response map;
    * a JSON-RPC response map on its own.

  A JSON-RPC response is decoded the way `Snodo.Client` decodes one, so both
  paths reach the same assertion.

  ## ExUnit

  ExUnit ships with Elixir, so it is on the code path of every Mix project,
  but `snodo` does not list it as an application and it is not started
  outside a test run. `Phoenix.ConnTest` and `Oban.Testing` call ExUnit from
  library code the same way. This module refers to ExUnit only to raise
  `ExUnit.AssertionError` when an assertion fails, so it compiles in every
  environment and nothing in it runs unless a test calls it.
  """

  alias Snodo.Client
  alias Snodo.Client.Page
  alias Snodo.Client.Response
  alias Snodo.Error
  alias Snodo.Server.Runtime

  @typedoc "A response from `Snodo.Client`, from `Snodo.Test.dispatch/2`, or a JSON-RPC response map."
  @type response :: Client.response() | {:ok, map()} | {:stream, term()} | map()

  @typedoc """
  An answer to one input request: the response map the request expects, or a
  function that receives the request's `params` and returns that map.
  """
  @type answer :: map() | (map() -> map())

  @typedoc """
  Answers keyed by input request kind (`:form`, `:url`, `:sampling`, or
  `:roots`) or by input request ID. An ID key wins over a kind key.
  """
  @type answers :: %{optional(Client.input_kind() | String.t()) => answer()} | keyword(answer())

  @kinds [:form, :url, :sampling, :roots]
  @list_keys ["tools", "resources", "resourceTemplates", "prompts"]

  ## Clients

  @doc """
  Builds a direct client for `runtime` with `Snodo.Client.direct/2`, and
  fails the test when the runtime refuses it.

  Takes the options of `Snodo.Client.direct/2`, and:

    * `:answers` - canned answers to input requests, keyed by kind (`:form`,
      `:url`, `:sampling`, or `:roots`). Each answer is the response map, or a
      function of the request's `params` that returns it. They become
      `:input_handlers`, so a call answers the server's input requests and
      returns the final result. An answer replaces an `:input_handlers` entry
      of the same kind.

  ```elixir
  accepted = %{"action" => "accept", "content" => %{"name" => "Ada"}}
  client = client!(MyServer.runtime(), answers: %{form: accepted})

  assert_tool_ok(Snodo.Client.call_tool(client, "greet_interactively"))
  ```
  """
  @spec client!(Runtime.t(), keyword()) :: Client.t()
  def client!(%Runtime{} = runtime, opts \\ []) when is_list(opts) do
    {answers, opts} = Keyword.pop(opts, :answers)
    opts = put_answer_handlers(opts, answers)

    case Client.direct(runtime, opts) do
      {:ok, client} ->
        client

      {:error, %Error{} = error} ->
        fail!("Expected a direct client for the runtime, got an error\n" <> describe_error(error))
    end
  end

  @doc """
  Builds a direct client whose requests run as `principal`.

  Handlers and authorization policies read `principal` as `context.auth`, as
  they would after a transport authenticated the request. Other options are
  those of `client!/2`.

  ```elixir
  reader = client_as(MyServer.runtime(), %{"role" => "reader"})
  assert_refused(Snodo.Client.call_tool(reader, "publish", %{}), -32_003)
  ```
  """
  @spec client_as(Runtime.t(), term(), keyword()) :: Client.t()
  def client_as(%Runtime{} = runtime, principal, opts \\ []) when is_list(opts) do
    client!(runtime, Keyword.put(opts, :auth, principal))
  end

  ## Tool results

  @doc """
  Asserts that a `tools/call` succeeded and the tool did not report an error.

  Returns the result map. Fails with the protocol error for an error
  response, with the input requests for an `input_required` result, and with
  the content for a result with `"isError" => true`.
  """
  @spec assert_tool_ok(response()) :: map()
  def assert_tool_ok(response) do
    expected = "Expected a successful tool result"

    case decode(response, expected) do
      {:ok, %{"isError" => true} = result} ->
        fail!("#{expected}, got isError: true\n" <> describe_tool_error(result))

      {:ok, result} ->
        result

      {:input_required, result} ->
        fail!("#{expected}, got input_required\n" <> describe_input_required(result))

      {:error, error} ->
        fail!("#{expected}, got an error response\n" <> describe_error(error))
    end
  end

  @doc """
  Asserts that a `tools/call` succeeded as a response but the tool reported
  an error, with `"isError" => true`.

  Returns the result map. When `text` is given, the text of the result's
  content must contain it (a string) or match it (a regex).
  """
  @spec assert_tool_error(response(), String.t() | Regex.t() | nil) :: map()
  def assert_tool_error(response, text \\ nil) do
    expected = "Expected a tool result with isError: true"

    case decode(response, expected) do
      {:ok, %{"isError" => true} = result} ->
        check_text(result, text)

      {:ok, result} ->
        fail!("#{expected}, got a successful result\n" <> describe_result(result))

      {:input_required, result} ->
        fail!("#{expected}, got input_required\n" <> describe_input_required(result))

      {:error, error} ->
        fail!("#{expected}, got an error response\n" <> describe_error(error))
    end
  end

  ## Input requests

  @doc """
  Asserts that a response is an `input_required` result.

  Returns the result map. When `kind` is given (`:form`, `:url`,
  `:sampling`, or `:roots`), at least one of its input requests must be of
  that kind.
  """
  @spec assert_input_required(response(), Client.input_kind() | nil) :: map()
  def assert_input_required(response, kind \\ nil) when is_nil(kind) or kind in @kinds do
    expected = "Expected an input_required result"

    case decode(response, expected) do
      {:input_required, result} ->
        check_kind(result, kind)

      {:ok, result} ->
        fail!("#{expected}, got a complete result\n" <> describe_result(result))

      {:error, error} ->
        fail!("#{expected}, got an error response\n" <> describe_error(error))
    end
  end

  @doc """
  Builds the options that answer an `input_required` result on the next
  request.

  Takes the result, or the `{:input_required, result}` tuple, and `answers`
  keyed by input request ID or by kind. Returns `input_responses:` with an
  answer for every input request and, when the result carries one,
  `request_state:`, ready to pass to `Snodo.Client.call_tool/4` or
  `Snodo.Client.request/4`. Fails when an input request has no answer.

  ```elixir
  result = assert_input_required(Snodo.Client.call_tool(client, "deploy"), :form)

  Snodo.Client.call_tool(client, "deploy", %{},
    answer_input(result, form: %{"action" => "accept", "content" => %{"confirm" => true}})
  )
  |> assert_tool_ok()
  ```
  """
  @spec answer_input({:input_required, map()} | map(), answers()) :: keyword()
  def answer_input({:input_required, result}, answers), do: answer_input(result, answers)

  def answer_input(%{} = result, answers) when is_map(answers) or is_list(answers) do
    answers = Map.new(answers)

    responses =
      result
      |> input_requests()
      |> Map.new(fn {id, request} -> {id, answer_one(id, request, answers)} end)

    case Map.fetch(result, "requestState") do
      {:ok, state} -> [input_responses: responses, request_state: state]
      :error -> [input_responses: responses]
    end
  end

  ## Errors

  @doc """
  Asserts that a response is a JSON-RPC error, such as an authorization
  refusal or a protocol error.

  Returns the `Snodo.Error`. When `code` is given, the error must carry it.
  """
  @spec assert_refused(response(), integer() | nil) :: Error.t()
  def assert_refused(response, code \\ nil) when is_nil(code) or is_integer(code) do
    expected =
      if code,
        do: "Expected an error response with code #{code}",
        else: "Expected an error response"

    case decode(response, expected) do
      {:error, %Error{code: actual} = error} when is_nil(code) or actual == code ->
        error

      {:error, error} ->
        fail!("#{expected}, got code #{error.code}\n" <> describe_error(error))

      {:input_required, result} ->
        fail!("#{expected}, got input_required\n" <> describe_input_required(result))

      {:ok, result} ->
        fail!("#{expected}, got a result\n" <> describe_result(result))
    end
  end

  ## Lists

  @doc """
  Asserts that a list includes the entry named `name`.

  `name` matches an entry's `"name"`, `"uri"`, or `"uriTemplate"`. The list
  is a response from `Snodo.Client.list_tools/1` and the other list
  functions, a `Snodo.Client.Page`, a response to a list request from
  `Snodo.Client.request/4` or `Snodo.Test.dispatch/2`, or a plain list.
  Returns the entry.
  """
  @spec assert_listed(response() | Page.t() | [map()], String.t()) :: map()
  def assert_listed(list, name) when is_binary(name) do
    entries = entries(list, "Expected a list including #{inspect(name)}")

    case Enum.find(entries, &(name in identifiers(&1))) do
      nil ->
        fail!("Expected a list including #{inspect(name)}\nlisted: #{inspect(listed(entries))}")

      entry ->
        entry
    end
  end

  @doc """
  Asserts that a list does not include the entry named `name`, as when an
  authorization policy hides a component from a principal.

  Takes the lists `assert_listed/2` takes. Returns the list's entries.
  """
  @spec refute_listed(response() | Page.t() | [map()], String.t()) :: [map()]
  def refute_listed(list, name) when is_binary(name) do
    entries = entries(list, "Expected a list without #{inspect(name)}")

    if Enum.any?(entries, &(name in identifiers(&1))) do
      fail!("Expected a list without #{inspect(name)}\nlisted: #{inspect(listed(entries))}")
    end

    entries
  end

  ## Decoding

  defp decode({:ok, %{"jsonrpc" => _version} = response}, expected),
    do: decode(response, expected)

  defp decode({:ok, result}, _expected) when is_map(result), do: {:ok, result}

  defp decode({:input_required, result}, _expected) when is_map(result),
    do: {:input_required, result}

  defp decode({:error, %Error{} = error}, _expected), do: {:error, error}

  defp decode({:stream, _subscription}, expected),
    do: fail!("#{expected}, got a subscriptions/listen stream")

  defp decode(%{"jsonrpc" => _version} = response, _expected), do: Response.decode(response)

  defp decode(other, expected),
    do: fail!("#{expected}, got a value that is not a response\nvalue: #{inspect(other)}")

  defp entries(list, _expected) when is_list(list), do: list
  defp entries({:ok, list}, _expected) when is_list(list), do: list
  defp entries(%Page{items: items}, _expected), do: items

  defp entries(response, expected) do
    case decode(response, expected) do
      {:ok, result} ->
        case Enum.find(@list_keys, &is_list(result[&1])) do
          nil ->
            fail!("#{expected}, got a result that is not a list\n" <> describe_result(result))

          key ->
            result[key]
        end

      {:input_required, result} ->
        fail!("#{expected}, got input_required\n" <> describe_input_required(result))

      {:error, error} ->
        fail!("#{expected}, got an error response\n" <> describe_error(error))
    end
  end

  defp identifiers(entry) when is_map(entry),
    do: entry |> Map.take(["name", "uri", "uriTemplate"]) |> Map.values()

  defp identifiers(_entry), do: []

  defp listed(entries), do: Enum.map(entries, &(&1 |> identifiers() |> List.first()))

  ## Checks

  defp check_text(result, nil), do: result

  defp check_text(result, expected) do
    text = content_text(result)

    matches? =
      case expected do
        %Regex{} -> Regex.match?(expected, text)
        expected when is_binary(expected) -> String.contains?(text, expected)
      end

    if matches? do
      result
    else
      fail!(
        "Expected the isError content to match #{inspect(expected)}\n" <>
          describe_tool_error(result)
      )
    end
  end

  defp check_kind(result, nil), do: result

  defp check_kind(result, kind) do
    kinds = result |> input_requests() |> Enum.map(fn {_id, request} -> kind(request) end)

    if kind in kinds do
      result
    else
      fail!(
        "Expected an input_required result with a #{describe_kind(kind)}\n" <>
          describe_input_required(result)
      )
    end
  end

  defp input_requests(result) do
    case Map.get(result, "inputRequests", %{}) do
      requests when is_map(requests) -> requests |> Enum.sort_by(fn {id, _request} -> id end)
      _invalid -> []
    end
  end

  defp kind(%{"method" => "elicitation/create", "params" => %{"mode" => "url"}}), do: :url
  defp kind(%{"method" => "elicitation/create"}), do: :form
  defp kind(%{"method" => "sampling/createMessage"}), do: :sampling
  defp kind(%{"method" => "roots/list"}), do: :roots
  defp kind(%{"method" => method}), do: method
  defp kind(_request), do: nil

  defp answer_one(id, request, answers) do
    kind = kind(request)
    params = params(request)

    case Map.fetch(answers, id) do
      {:ok, answer} ->
        resolve_answer(answer, params)

      :error ->
        case Map.fetch(answers, kind) do
          {:ok, answer} ->
            resolve_answer(answer, params)

          :error ->
            fail!(
              "No answer for input request #{inspect(id)}, a #{describe_kind(kind)}\n" <>
                "request: #{inspect(request, pretty: true)}"
            )
        end
    end
  end

  defp params(%{"params" => params}) when is_map(params), do: params
  defp params(_request), do: %{}

  defp resolve_answer(answer, params) when is_function(answer, 1), do: answer.(params)
  defp resolve_answer(%{} = answer, _params), do: answer

  defp put_answer_handlers(opts, nil), do: opts

  defp put_answer_handlers(opts, answers) when is_map(answers) or is_list(answers) do
    handlers =
      Map.new(answers, fn
        {kind, answer} when kind in @kinds and (is_map(answer) or is_function(answer, 1)) ->
          {kind, fn params -> {:ok, resolve_answer(answer, params)} end}

        {kind, answer} ->
          raise ArgumentError,
                ":answers takes a kind in #{inspect(@kinds)} and a map or a function " <>
                  "of one argument, got: #{inspect({kind, answer})}"
      end)

    Keyword.update(opts, :input_handlers, handlers, &Map.merge(&1, handlers))
  end

  defp put_answer_handlers(_opts, answers) do
    raise ArgumentError, ":answers must be a map or a keyword list, got: #{inspect(answers)}"
  end

  ## Failure messages

  defp describe_error(%Error{} = error) do
    lines = [
      "code: #{error.code}",
      "message: #{inspect(error.message)}",
      if(error.data != nil, do: "data: #{inspect(error.data, pretty: true)}")
    ]

    lines |> Enum.reject(&is_nil/1) |> Enum.join("\n")
  end

  defp describe_tool_error(result) do
    lines = [
      "content:\n" <> indent(content_text(result)),
      if(Map.has_key?(result, "structuredContent"),
        do: "structuredContent: #{inspect(result["structuredContent"], pretty: true)}"
      )
    ]

    lines |> Enum.reject(&is_nil/1) |> Enum.join("\n")
  end

  defp describe_input_required(result) do
    requests =
      result
      |> input_requests()
      |> Enum.map(fn {id, request} ->
        "  #{inspect(id)}: #{describe_kind(kind(request))} #{inspect(params(request))}"
      end)

    state =
      if Map.has_key?(result, "requestState"), do: ["requestState: present"], else: []

    Enum.join(["inputRequests:" | requests] ++ state, "\n")
  end

  defp describe_result(result), do: "result: #{inspect(result, pretty: true)}"

  defp describe_kind(:form), do: "form elicitation"
  defp describe_kind(:url), do: "URL elicitation"
  defp describe_kind(:sampling), do: "sampling request"
  defp describe_kind(:roots), do: "roots request"
  defp describe_kind(nil), do: "request without a method"
  defp describe_kind(method), do: "#{method} request"

  defp content_text(result) do
    result
    |> Map.get("content", [])
    |> List.wrap()
    |> Enum.map_join("\n", fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      block -> inspect(block)
    end)
  end

  defp indent(text), do: text |> String.split("\n") |> Enum.map_join("\n", &("    " <> &1))

  @spec fail!(String.t()) :: no_return()
  defp fail!(message), do: raise(ExUnit.AssertionError, message: message)
end
