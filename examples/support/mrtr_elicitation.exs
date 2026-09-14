defmodule Examples.MRTR.Workflow do
  @moduledoc false

  alias MCP.Elicitation
  alias MCP.MRTR.State
  alias MCP.Result

  # This read-only, loopback example uses a process-lifetime secret. Remote
  # applications must configure a shared secret and a verified auth principal.
  def configure do
    Application.put_env(:mcp_ex, :mrtr_example_secret, :crypto.strong_rand_bytes(32))
  end

  def preference(context) do
    with {:ok, state} <- state(context) do
      case state do
        nil -> ask(context, "color", %{"phase" => "color"})
        %{"phase" => "color"} -> color(context)
        %{"phase" => "style", "color" => color} -> style(context, color)
        _other -> {:error, MCP.Error.invalid_params("Unexpected preference continuation")}
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
        _other -> {:error, MCP.Error.invalid_params("Unexpected URL continuation")}
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
          {:error, MCP.Error.invalid_params("Unexpected reset continuation")}
      end
    end
  end

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
      secret: Application.fetch_env!(:mcp_ex, :mrtr_example_secret),
      # This deliberately anonymous loopback preview has no authenticated user.
      principal: nil,
      ttl: 300
    ]
  end
end

defmodule Examples.MRTR.PreferenceTool do
  @moduledoc false
  alias Examples.MRTR.Workflow

  use MCP.Tool.Simple,
    name: "preference_preview",
    description: "Build a read-only preference preview"

  argument("subject", :string, required: true)

  @impl true
  def call(_arguments, context) do
    case Workflow.preference(context) do
      {:done, data} -> {:ok, MCP.Result.text(JSON.encode!(data))}
      other -> other
    end
  end
end

defmodule Examples.MRTR.URLTool do
  @moduledoc false
  alias Examples.MRTR.Workflow

  use MCP.Tool.Simple,
    name: "url_preview",
    description: "Show that URL consent is not external completion"

  @impl true
  def call(_arguments, context) do
    case Workflow.url_preview(context) do
      {:done, data} -> {:ok, MCP.Result.text(JSON.encode!(data))}
      other -> other
    end
  end
end

defmodule Examples.MRTR.ResetTool do
  @moduledoc false
  alias Examples.MRTR.Workflow

  use MCP.Tool.Simple,
    name: "reset_preview",
    description: "Demonstrate state-only and input-only continuations"

  @impl true
  def call(_arguments, context) do
    case Workflow.reset_preview(context) do
      {:done, data} -> {:ok, MCP.Result.text(JSON.encode!(data))}
      other -> other
    end
  end
end

defmodule Examples.MRTR.PreferenceResource do
  @moduledoc false
  alias Examples.MRTR.Workflow

  use MCP.Resource,
    uri: "preview://preferences",
    name: "Preference preview",
    mime_type: "application/json"

  @impl true
  def read(%{"uri" => uri}, context) do
    case Workflow.preference(context) do
      {:done, data} -> {:ok, MCP.Result.resource_read(MCP.Resource.json(uri, data))}
      other -> other
    end
  end
end

defmodule Examples.MRTR.PreferencePrompt do
  @moduledoc false
  alias Examples.MRTR.Workflow

  use MCP.Prompt,
    name: "preference_prompt",
    description: "Render a prompt after eliciting preferences"

  @impl true
  def render(_arguments, context) do
    case Workflow.preference(context) do
      {:done, data} ->
        {:ok,
         MCP.Result.prompt_get(MCP.Prompt.message(:user, MCP.Prompt.text(JSON.encode!(data))))}

      other ->
        other
    end
  end
end

defmodule Examples.MRTR.Server do
  @moduledoc false
  use MCP.Server,
    name: "mrtr-example",
    version: "1.0.0",
    protocols: [MCP.Protocol.V2026_07_28],
    schema_validator: MCP.Schema.Validator.Basic

  tool(Examples.MRTR.PreferenceTool)
  tool(Examples.MRTR.URLTool)
  tool(Examples.MRTR.ResetTool)
  resource(Examples.MRTR.PreferenceResource)
  prompt(Examples.MRTR.PreferencePrompt)
end
