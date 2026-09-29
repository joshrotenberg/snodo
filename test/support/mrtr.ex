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
  def call(%{"variant" => variant}, _context), do: {:ok, variant(variant)}

  defp variant("empty"), do: Snodo.Result.input_required()
  defp variant("state_null"), do: Snodo.Result.input_required(request_state: nil)
  defp variant("bad_request"), do: Snodo.Result.input_required(input_requests: %{"x" => %{}})

  defp variant("unknown_kind") do
    Snodo.Result.input_required(
      input_requests: %{"x" => %{"method" => "logging/setLevel", "params" => %{}}}
    )
  end

  defp variant("bad_sampling") do
    Snodo.Result.input_required(
      input_requests: %{
        "x" => %{"method" => "sampling/createMessage", "params" => %{"messages" => []}}
      }
    )
  end

  defp variant("bad_roots") do
    Snodo.Result.input_required(
      input_requests: %{"x" => %{"method" => "roots/list", "params" => %{"cursor" => 1}}}
    )
  end

  defp variant("state_only"),
    do: Snodo.Result.input_required(request_state: "unused-opaque-marker")

  defp variant("empty_requests"), do: Snodo.Result.input_required(input_requests: %{})

  defp variant("url") do
    Snodo.Result.input_required(
      input_requests: %{
        "x" => Snodo.Elicitation.url("Preview", "https://example.invalid/preview")
      }
    )
  end
end

defmodule SnodoTest.MRTR.Sample do
  @moduledoc false
  alias Snodo.Prompt
  alias Snodo.Result
  alias Snodo.Sampling

  # The "tools" and "context" arguments opt into the sampling settings that
  # need sampling.tools and sampling.context on the client.
  def request(arguments \\ %{}) do
    tools =
      if arguments["tools"],
        do: [
          tools: [%{"name" => "lookup", "inputSchema" => %{"type" => "object"}}],
          tool_choice: %{"mode" => "auto"}
        ],
        else: []

    context = if arguments["context"], do: [include_context: "thisServer"], else: []

    Sampling.create_message(
      [Prompt.message(:user, Prompt.text("Summarize the label"))],
      [max_tokens: 64] ++ tools ++ context
    )
  end

  def run(context, id, request, complete) do
    case Sampling.response(context, id, request) do
      :missing ->
        {:ok, Result.input_required(input_requests: %{id => request})}

      {:ok, %{"content" => %{"type" => "text", "text" => text}, "model" => model}} ->
        {:ok, complete.(%{"summary" => text, "model" => model})}

      {:ok, %{"content" => content}} ->
        {:ok, complete.(%{"content" => content})}

      {:error, error} ->
        {:error, error}
    end
  end
end

defmodule SnodoTest.MRTR.SamplingTool do
  @moduledoc false
  use Snodo.Tool, name: "sample"
  alias SnodoTest.MRTR.Sample

  @impl true
  def call(arguments, context) do
    Sample.run(context, "summary", Sample.request(arguments), &Snodo.Result.structured/1)
  end
end

defmodule SnodoTest.MRTR.SamplingResource do
  @moduledoc false
  use Snodo.Resource, name: "sample", uri: "sample://value"
  alias SnodoTest.MRTR.Sample

  @impl true
  def read(%{"uri" => uri}, context) do
    Sample.run(context, "summary", Sample.request(), fn value ->
      Snodo.Result.resource_read(Snodo.Resource.json(uri, value))
    end)
  end
end

defmodule SnodoTest.MRTR.SamplingPrompt do
  @moduledoc false
  use Snodo.Prompt, name: "sample", arguments: []
  alias SnodoTest.MRTR.Sample

  @impl true
  def render(_arguments, context) do
    Sample.run(context, "summary", Sample.request(), fn value ->
      Snodo.Result.prompt_get(Snodo.Prompt.message(:user, Snodo.Prompt.text(JSON.encode!(value))))
    end)
  end
end

defmodule SnodoTest.MRTR.RootsTool do
  @moduledoc false
  use Snodo.Tool, name: "roots"
  alias Snodo.Result
  alias Snodo.Roots

  @impl true
  def call(_arguments, context) do
    request = Roots.list()

    case Roots.response(context, "client_roots", request) do
      :missing ->
        {:ok, Result.input_required(input_requests: %{"client_roots" => request})}

      {:ok, %{"roots" => roots}} ->
        {:ok, Result.structured(%{"uris" => Enum.map(roots, & &1["uri"])})}

      {:error, error} ->
        {:error, error}
    end
  end
end

defmodule SnodoTest.MRTR.MixedTool do
  @moduledoc false
  # One elicitation, one sampling, and one roots request in a single result.
  # No state: every retry re-requests exactly the answers still missing.
  use Snodo.Tool, name: "mixed"

  alias Snodo.Elicitation
  alias Snodo.Result
  alias Snodo.Roots
  alias Snodo.Sampling
  alias SnodoTest.MRTR.Choice
  alias SnodoTest.MRTR.Sample

  @impl true
  def call(_arguments, context) do
    requests = %{
      "choice" => Choice.request(),
      "summary" => Sample.request(),
      "client_roots" => Roots.list()
    }

    readers = %{
      "choice" => &Elicitation.response/3,
      "summary" => &Sampling.response/3,
      "client_roots" => &Roots.response/3
    }

    requests
    |> Enum.reduce_while({:ok, %{}, %{}}, fn {id, request}, {:ok, answers, missing} ->
      case readers[id].(context, id, request) do
        :missing -> {:cont, {:ok, answers, Map.put(missing, id, request)}}
        {:ok, response} -> {:cont, {:ok, Map.put(answers, id, response), missing}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, answers, missing} when map_size(missing) == 0 -> {:ok, Result.structured(answers)}
      {:ok, _answers, missing} -> {:ok, Result.input_required(input_requests: missing)}
      {:error, error} -> {:error, error}
    end
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
  tool(SnodoTest.MRTR.SamplingTool)
  tool(SnodoTest.MRTR.RootsTool)
  tool(SnodoTest.MRTR.MixedTool)
  resource(SnodoTest.MRTR.Resource)
  resource(SnodoTest.MRTR.SamplingResource)
  prompt(SnodoTest.MRTR.Prompt)
  prompt(SnodoTest.MRTR.SamplingPrompt)
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
