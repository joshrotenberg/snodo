defmodule MCPEx.MRTR.Choice do
  @moduledoc false
  alias MCP.Elicitation
  alias MCP.Result

  def request do
    Elicitation.form("Choose a label", %{
      "type" => "object",
      "properties" => %{"label" => %{"type" => "string", "minLength" => 1}},
      "required" => ["label"]
    })
  end

  def run(context, complete) do
    case Elicitation.response(context, "choice", request()) do
      :missing ->
        {:ok, Result.input_required(input_requests: %{"choice" => request()})}

      {:ok, %{"action" => "accept", "content" => %{"label" => label}}} ->
        {:ok, complete.(label)}

      {:ok, %{"action" => action}} ->
        {:ok, complete.(action)}

      {:error, error} ->
        {:error, error}
    end
  end
end

defmodule MCPEx.MRTR.Tool do
  @moduledoc false
  use MCP.Tool, name: "choice"
  alias MCPEx.MRTR.Choice
  input_schema(%{"type" => "object", "properties" => %{}, "additionalProperties" => false})

  output_schema(%{
    "type" => "object",
    "properties" => %{"label" => %{"type" => "string"}},
    "required" => ["label"]
  })

  @impl true
  def call(arguments, context) do
    if arguments != %{}, do: raise("retry data leaked into tool arguments")
    Choice.run(context, &MCP.Result.structured(%{"label" => &1}))
  end
end

defmodule MCPEx.MRTR.Resource do
  @moduledoc false
  use MCP.Resource, name: "choice", uri: "choice://value"
  alias MCPEx.MRTR.Choice

  @impl true
  def read(%{"uri" => uri}, context) do
    Choice.run(context, &MCP.Result.resource_read(MCP.Resource.text(uri, &1)))
  end
end

defmodule MCPEx.MRTR.Prompt do
  @moduledoc false
  use MCP.Prompt, name: "choice", arguments: []
  alias MCPEx.MRTR.Choice

  @impl true
  def render(arguments, context) do
    if arguments != %{}, do: raise("retry data leaked into prompt arguments")

    Choice.run(context, fn label ->
      MCP.Result.prompt_get(MCP.Prompt.message(:user, MCP.Prompt.text(label)))
    end)
  end
end

defmodule MCPEx.MRTR.InvalidTool do
  @moduledoc false
  use MCP.Tool, name: "invalid_input"

  @impl true
  def call(%{"variant" => variant}, _context) do
    result =
      case variant do
        "empty" ->
          MCP.Result.input_required()

        "state_null" ->
          MCP.Result.input_required(request_state: nil)

        "bad_request" ->
          MCP.Result.input_required(input_requests: %{"x" => %{}})

        "roots" ->
          MCP.Result.input_required(input_requests: %{"x" => %{"method" => "roots/list"}})

        "state_only" ->
          MCP.Result.input_required(request_state: "unused-opaque-marker")

        "empty_requests" ->
          MCP.Result.input_required(input_requests: %{})

        "url" ->
          MCP.Result.input_required(
            input_requests: %{
              "x" => MCP.Elicitation.url("Preview", "https://example.invalid/preview")
            }
          )
      end

    {:ok, result}
  end
end

defmodule MCPEx.MRTR.Server do
  @moduledoc false
  use MCP.Server,
    name: "mrtr-test",
    version: "1",
    schema_validator: MCP.Schema.Validator.Basic,
    resources_cache: [ttl_ms: 5000, scope: "public"]

  tool(MCPEx.MRTR.Tool)
  tool(MCPEx.MRTR.InvalidTool)
  tool(MCPEx.MRTR.MultipleTool)
  resource(MCPEx.MRTR.Resource)
  prompt(MCPEx.MRTR.Prompt)
end

defmodule MCPEx.MRTR.MultipleTool do
  @moduledoc false
  use MCP.Tool, name: "multiple_choices"

  alias MCP.Elicitation
  alias MCP.Error
  alias MCP.MRTR.State
  alias MCP.Result
  alias MCPEx.MRTR.Choice

  # A public test fixture key, never application configuration.
  @state_opts [secret: "test-only-key-never-use-in-an-app!", principal: nil]

  @impl true
  def call(_arguments, context) do
    with {:ok, previous} <- previous(context),
         {:ok, answers} <- collect(context, previous) do
      missing =
        for key <- ["first", "second"],
            not Map.has_key?(answers, key),
            into: %{},
            do: {key, Choice.request()}

      if map_size(missing) == 0 do
        {:ok, Result.structured(answers)}
      else
        {:ok,
         Result.input_required(
           input_requests: missing,
           request_state: State.seal(answers, context, @state_opts)
         )}
      end
    end
  end

  defp previous(%{request_state: nil}), do: {:ok, %{}}
  defp previous(context), do: State.open(context.request_state, context, @state_opts)

  defp collect(context, previous) do
    Enum.reduce_while(["first", "second"], {:ok, previous}, fn key, {:ok, answers} ->
      case Elicitation.response(context, key, Choice.request()) do
        :missing ->
          {:cont, {:ok, answers}}

        {:ok, %{"action" => "accept", "content" => %{"label" => label}}} ->
          {:cont, {:ok, Map.put(answers, key, label)}}

        {:ok, _dismissed} ->
          {:halt, {:error, Error.invalid_params("Selection not accepted")}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
  end
end
