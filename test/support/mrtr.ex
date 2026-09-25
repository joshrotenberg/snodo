defmodule SnodoTest.MRTR.Choice do
  @moduledoc false
  alias Snodo.Elicitation
  alias Snodo.Result

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

defmodule SnodoTest.MRTR.Tool do
  @moduledoc false
  use Snodo.Tool, name: "choice"
  alias SnodoTest.MRTR.Choice
  input_schema(%{"type" => "object", "properties" => %{}, "additionalProperties" => false})

  output_schema(%{
    "type" => "object",
    "properties" => %{"label" => %{"type" => "string"}},
    "required" => ["label"]
  })

  @impl true
  def call(arguments, context) do
    if arguments != %{}, do: raise("retry data leaked into tool arguments")
    Choice.run(context, &Snodo.Result.structured(%{"label" => &1}))
  end
end

defmodule SnodoTest.MRTR.Resource do
  @moduledoc false
  use Snodo.Resource, name: "choice", uri: "choice://value"
  alias SnodoTest.MRTR.Choice

  @impl true
  def read(%{"uri" => uri}, context) do
    Choice.run(context, &Snodo.Result.resource_read(Snodo.Resource.text(uri, &1)))
  end
end

defmodule SnodoTest.MRTR.Prompt do
  @moduledoc false
  use Snodo.Prompt, name: "choice", arguments: []
  alias SnodoTest.MRTR.Choice

  @impl true
  def render(arguments, context) do
    if arguments != %{}, do: raise("retry data leaked into prompt arguments")

    Choice.run(context, fn label ->
      Snodo.Result.prompt_get(Snodo.Prompt.message(:user, Snodo.Prompt.text(label)))
    end)
  end
end

defmodule SnodoTest.MRTR.InvalidTool do
  @moduledoc false
  use Snodo.Tool, name: "invalid_input"

  @impl true
  def call(%{"variant" => variant}, _context) do
    result =
      case variant do
        "empty" ->
          Snodo.Result.input_required()

        "state_null" ->
          Snodo.Result.input_required(request_state: nil)

        "bad_request" ->
          Snodo.Result.input_required(input_requests: %{"x" => %{}})

        "roots" ->
          Snodo.Result.input_required(input_requests: %{"x" => %{"method" => "roots/list"}})

        "state_only" ->
          Snodo.Result.input_required(request_state: "unused-opaque-marker")

        "empty_requests" ->
          Snodo.Result.input_required(input_requests: %{})

        "url" ->
          Snodo.Result.input_required(
            input_requests: %{
              "x" => Snodo.Elicitation.url("Preview", "https://example.invalid/preview")
            }
          )
      end

    {:ok, result}
  end
end

defmodule SnodoTest.MRTR.Server do
  @moduledoc false
  use Snodo.Server,
    name: "mrtr-test",
    version: "1",
    schema_validator: Snodo.Schema.Validator.Basic,
    resources_cache: [ttl_ms: 5000, scope: "public"]

  tool(SnodoTest.MRTR.Tool)
  tool(SnodoTest.MRTR.InvalidTool)
  tool(SnodoTest.MRTR.MultipleTool)
  resource(SnodoTest.MRTR.Resource)
  prompt(SnodoTest.MRTR.Prompt)
end

defmodule SnodoTest.MRTR.MultipleTool do
  @moduledoc false
  use Snodo.Tool, name: "multiple_choices"

  alias Snodo.Elicitation
  alias Snodo.Error
  alias Snodo.MRTR.State
  alias Snodo.Result
  alias SnodoTest.MRTR.Choice

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
