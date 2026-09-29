defmodule Examples.MRTR.Workflow do
  @moduledoc false

  alias Snodo.Elicitation
  alias Snodo.MRTR.State
  alias Snodo.Result
  alias Snodo.Roots
  alias Snodo.Sampling

  # This read-only, loopback example uses a process-lifetime secret. Remote
  # applications must configure a shared secret and a verified auth principal.
  def configure do
    Application.put_env(:snodo, :mrtr_example_secret, :crypto.strong_rand_bytes(32))
  end

  def preference(context) do
    with {:ok, state} <- state(context) do
      case state do
        nil -> ask(context, "color", %{"phase" => "color"})
        %{"phase" => "color"} -> color(context)
        %{"phase" => "style", "color" => color} -> style(context, color)
        _other -> {:error, Snodo.Error.invalid_params("Unexpected preference continuation")}
      end
    end
  end

  def url_preview(context) do
    request =
      Elicitation.url(
        "Preview consent only; no browser will be opened",
        "https://example.invalid/preferences"
      )

    with {:ok, state} <- state(context) do
      case state do
        nil -> suspend(context, "visit", request, %{"phase" => "visit"})
        %{"phase" => "visit"} -> url_response(context, request)
        _other -> {:error, Snodo.Error.invalid_params("Unexpected URL continuation")}
      end
    end
  end

  # A state-only retry followed by an input-only retry shows that clients must
  # discard a previous token when the latest InputRequiredResult omits it.
  def reset_preview(context) do
    request = field("label")

    with {:ok, state} <- state(context) do
      case state do
        nil ->
          reset_response(context, request)

        %{"phase" => "reset"} ->
          {:ok, Result.input_required(input_requests: %{"label" => request})}

        _other ->
          {:error, Snodo.Error.invalid_params("Unexpected reset continuation")}
      end
    end
  end

  # SEP-2577 deprecates the embedded sampling and roots requests. The official
  # client still fulfils them through its registered handlers, so these three
  # stateless workflows exercise them: each retry re-requests only the answers
  # still missing.
  def sampling_preview(context) do
    case Sampling.response(context, "summary", sampling_request()) do
      :missing -> suspend_stateless(%{"summary" => sampling_request()})
      {:ok, response} -> {:done, summary(response)}
      {:error, error} -> {:error, error}
    end
  end

  def roots_preview(context) do
    case Roots.response(context, "roots", Roots.list()) do
      :missing -> suspend_stateless(%{"roots" => Roots.list()})
      {:ok, response} -> {:done, %{"roots" => uris(response)}}
      {:error, error} -> {:error, error}
    end
  end

  def mixed_preview(context) do
    requests = %{
      "label" => field("label"),
      "summary" => sampling_request(),
      "roots" => Roots.list()
    }

    readers = %{
      "label" => &Elicitation.response/3,
      "summary" => &Sampling.response/3,
      "roots" => &Roots.response/3
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
      {:ok, answers, missing} when map_size(missing) == 0 ->
        {:done,
         summary(answers["summary"])
         |> Map.put("label", get_in(answers, ["label", "content", "label"]))
         |> Map.put("roots", uris(answers["roots"]))}

      {:ok, _answers, missing} ->
        suspend_stateless(missing)

      {:error, error} ->
        {:error, error}
    end
  end

  defp sampling_request do
    Sampling.create_message(
      [Snodo.Prompt.message(:user, Snodo.Prompt.text("Summarize the preview in one line"))],
      max_tokens: 32,
      system_prompt: "Answer in one sentence"
    )
  end

  # Sampled content is model output the client chose to return; it is echoed
  # here as data, never followed as an instruction.
  defp summary(%{"content" => %{"type" => "text", "text" => text}, "model" => model}),
    do: %{"summary" => text, "model" => model}

  defp summary(%{"model" => model}), do: %{"summary" => nil, "model" => model}

  defp uris(%{"roots" => roots}), do: Enum.map(roots, & &1["uri"])

  defp suspend_stateless(requests), do: {:ok, Result.input_required(input_requests: requests)}

  defp reset_response(context, request) do
    case Elicitation.response(context, "label", request) do
      :missing ->
        {:ok, Result.input_required(request_state: seal(%{"phase" => "reset"}, context))}

      {:ok, response} ->
        {:done, %{"status" => response["action"], "stateDiscarded" => true}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp color(context) do
    case Elicitation.response(context, "color", field("color")) do
      :missing ->
        ask(context, "color", %{"phase" => "color"})

      {:ok, %{"action" => "accept", "content" => %{"color" => color}}} ->
        ask(context, "style", %{"phase" => "style", "color" => color})

      {:ok, response} ->
        {:done, %{"status" => response["action"]}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp style(context, color) do
    case Elicitation.response(context, "style", field("style")) do
      :missing ->
        ask(context, "style", %{"phase" => "style", "color" => color})

      {:ok, %{"action" => "accept", "content" => %{"style" => style}}} ->
        {:done, %{"color" => color, "style" => style, "status" => "preview"}}

      {:ok, response} ->
        {:done, %{"status" => response["action"]}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp url_response(context, request) do
    case Elicitation.response(context, "visit", request) do
      :missing ->
        suspend(context, "visit", request, %{"phase" => "visit"})

      {:ok, response} ->
        # Acceptance is consent, NOT proof that an external interaction finished.
        {:done, %{"consent" => response["action"], "externalStatus" => "pending"}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp field(name) do
    Elicitation.form("Choose #{name} for a read-only preview", %{
      "type" => "object",
      "properties" => %{name => %{"type" => "string", "minLength" => 1}},
      "required" => [name]
    })
  end

  defp ask(context, name, state), do: suspend(context, name, field(name), state)

  defp suspend(context, name, request, state) do
    {:ok,
     Result.input_required(
       input_requests: %{name => request},
       request_state: seal(state, context)
     )}
  end

  defp state(%{request_state: nil}), do: {:ok, nil}
  defp state(context), do: State.open(context.request_state, context, state_options())
  defp seal(value, context), do: State.seal(value, context, state_options())

  defp state_options do
    [
      secret: Application.fetch_env!(:snodo, :mrtr_example_secret),
      # This deliberately anonymous loopback preview has no authenticated user.
      principal: nil,
      ttl: 300
    ]
  end
end

defmodule Examples.MRTR.PreferenceTool do
  @moduledoc false
  alias Examples.MRTR.Workflow

  use Snodo.Tool.Simple,
    name: "preference_preview",
    description: "Build a read-only preference preview"

  argument("subject", :string, required: true)

  @impl true
  def call(_arguments, context) do
    case Workflow.preference(context) do
      {:done, data} -> {:ok, Snodo.Result.text(JSON.encode!(data))}
      other -> other
    end
  end
end

defmodule Examples.MRTR.URLTool do
  @moduledoc false
  alias Examples.MRTR.Workflow

  use Snodo.Tool.Simple,
    name: "url_preview",
    description: "Show that URL consent is not external completion"

  @impl true
  def call(_arguments, context) do
    case Workflow.url_preview(context) do
      {:done, data} -> {:ok, Snodo.Result.text(JSON.encode!(data))}
      other -> other
    end
  end
end

defmodule Examples.MRTR.ResetTool do
  @moduledoc false
  alias Examples.MRTR.Workflow

  use Snodo.Tool.Simple,
    name: "reset_preview",
    description: "Demonstrate state-only and input-only continuations"

  @impl true
  def call(_arguments, context) do
    case Workflow.reset_preview(context) do
      {:done, data} -> {:ok, Snodo.Result.text(JSON.encode!(data))}
      other -> other
    end
  end
end

defmodule Examples.MRTR.SamplingTool do
  @moduledoc false
  alias Examples.MRTR.Workflow

  use Snodo.Tool.Simple,
    name: "sampling_preview",
    description: "Ask the client for a sampled one-line summary (deprecated by SEP-2577)"

  @impl true
  def call(_arguments, context) do
    case Workflow.sampling_preview(context) do
      {:done, data} -> {:ok, Snodo.Result.text(JSON.encode!(data))}
      other -> other
    end
  end
end

defmodule Examples.MRTR.RootsTool do
  @moduledoc false
  alias Examples.MRTR.Workflow

  use Snodo.Tool.Simple,
    name: "roots_preview",
    description: "Ask the client for its roots (deprecated by SEP-2577)"

  @impl true
  def call(_arguments, context) do
    case Workflow.roots_preview(context) do
      {:done, data} -> {:ok, Snodo.Result.text(JSON.encode!(data))}
      other -> other
    end
  end
end

defmodule Examples.MRTR.MixedTool do
  @moduledoc false
  alias Examples.MRTR.Workflow

  use Snodo.Tool.Simple,
    name: "mixed_preview",
    description: "Ask for a form, a sampled summary, and the roots in one round"

  @impl true
  def call(_arguments, context) do
    case Workflow.mixed_preview(context) do
      {:done, data} -> {:ok, Snodo.Result.text(JSON.encode!(data))}
      other -> other
    end
  end
end

defmodule Examples.MRTR.PreferenceResource do
  @moduledoc false
  alias Examples.MRTR.Workflow

  use Snodo.Resource,
    uri: "preview://preferences",
    name: "Preference preview",
    mime_type: "application/json"

  @impl true
  def read(%{"uri" => uri}, context) do
    case Workflow.preference(context) do
      {:done, data} -> {:ok, Snodo.Result.resource_read(Snodo.Resource.json(uri, data))}
      other -> other
    end
  end
end

defmodule Examples.MRTR.PreferencePrompt do
  @moduledoc false
  alias Examples.MRTR.Workflow

  use Snodo.Prompt,
    name: "preference_prompt",
    description: "Render a prompt after eliciting preferences"

  @impl true
  def render(_arguments, context) do
    case Workflow.preference(context) do
      {:done, data} ->
        {:ok,
         Snodo.Result.prompt_get(
           Snodo.Prompt.message(:user, Snodo.Prompt.text(JSON.encode!(data)))
         )}

      other ->
        other
    end
  end
end

defmodule Examples.MRTR.Server do
  @moduledoc false
  use Snodo.Server,
    name: "mrtr-example",
    version: "1.0.0",
    protocols: [Snodo.Protocol.V2026_07_28],
    schema_validator: Snodo.Schema.Validator.Basic

  tool(Examples.MRTR.PreferenceTool)
  tool(Examples.MRTR.URLTool)
  tool(Examples.MRTR.ResetTool)
  tool(Examples.MRTR.SamplingTool)
  tool(Examples.MRTR.RootsTool)
  tool(Examples.MRTR.MixedTool)
  resource(Examples.MRTR.PreferenceResource)
  prompt(Examples.MRTR.PreferencePrompt)
end
