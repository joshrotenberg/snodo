defmodule MCPEx.Conformance.MRTR.Workflow do
  @moduledoc false

  alias MCP.Elicitation
  alias MCP.Error
  alias MCP.MRTR.State
  alias MCP.Result

  # The fixture is anonymous, read-only, and loopback-only. This process-lifetime
  # random secret is not a deployable authentication or durable workflow policy.
  def configure do
    Application.put_env(:mcp_ex, :conformance_mrtr_secret, :crypto.strong_rand_bytes(32))
  end

  def field(name, type \\ "string") do
    Elicitation.form("Please provide #{name}", %{
      "type" => "object",
      "properties" => %{name => %{"type" => type}},
      "required" => [name]
    })
  end

  def single(context, id, request, complete) do
    case Elicitation.response(context, id, request) do
      :missing -> {:ok, Result.input_required(input_requests: %{id => request})}
      {:ok, response} -> {:ok, complete.(response)}
      {:error, error} -> {:error, error}
    end
  end

  def greeting(context) do
    single(context, "user_name", field("name"), fn
      %{"action" => "accept", "content" => %{"name" => name}} ->
        Result.text("Hello, #{name}!")

      %{"action" => action} ->
        Result.text("Name request #{action}; no greeting generated")
    end)
  end

  def confirmation(context) do
    with {:ok, state} <- state(context) do
      confirm(state, context)
    end
  end

  def multi_round(context) do
    with {:ok, state} <- state(context) do
      round(state, context)
    end
  end

  defp confirm(nil, context) do
    suspend(context, %{"confirm" => field("ok", "boolean")}, %{"phase" => "confirm"})
  end

  defp confirm(%{"phase" => "confirm"} = state, context) do
    consume(context, "confirm", field("ok", "boolean"), state, fn response ->
      {:ok, Result.text("state-ok: #{JSON.encode!(response)}")}
    end)
  end

  defp confirm(_other, _context), do: invalid_state()

  defp round(nil, context) do
    suspend(context, %{"step1" => field("name")}, %{"phase" => "name"})
  end

  defp round(%{"phase" => "name"} = state, context) do
    consume(context, "step1", field("name"), state, fn
      %{"action" => "accept", "content" => %{"name" => name}} ->
        suspend(context, %{"step2" => field("color")}, %{"phase" => "color", "name" => name})

      response ->
        cancelled(response)
    end)
  end

  defp round(%{"phase" => "color", "name" => name} = state, context) do
    consume(context, "step2", field("color"), state, fn
      %{"action" => "accept", "content" => %{"color" => color}} ->
        {:ok, Result.text("Hello, #{name}; your favorite color is #{color}.")}

      response ->
        cancelled(response)
    end)
  end

  defp round(_other, _context), do: invalid_state()

  # This elicitation-only fixture is intentionally NOT named as alpha.11's
  # multiple-inputs fixture, which also requires unsupported sampling and roots.
  def parallel_forms(context) do
    with {:ok, state} <- state(context) do
      case state do
        nil ->
          suspend(context, parallel_requests(), %{"phase" => "parallel", "answers" => %{}})

        %{"phase" => "parallel", "answers" => answers} ->
          collect_parallel(context, answers)

        _other ->
          invalid_state()
      end
    end
  end

  def url_consent(context) do
    request =
      Elicitation.url(
        "Preview consent only; the fixture does not navigate or perform an external operation",
        "https://example.invalid/conformance-preview"
      )

    single(context, "visit", request, fn response ->
      Result.text(JSON.encode!(%{"consent" => response["action"], "externalStatus" => "pending"}))
    end)
  end

  defp collect_parallel(context, answers) do
    parallel_requests()
    |> Map.drop(Map.keys(answers))
    |> Enum.reduce_while({:ok, answers}, fn {id, request}, {:ok, collected} ->
      case Elicitation.response(context, id, request) do
        :missing ->
          {:cont, {:ok, collected}}

        {:ok, %{"action" => "accept", "content" => content}} ->
          {:cont, {:ok, Map.put(collected, id, Map.fetch!(content, id))}}

        {:ok, response} ->
          {:halt, {:cancelled, response}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
    |> finish_parallel(context)
  end

  defp finish_parallel({:ok, answers}, context) do
    pending = Map.drop(parallel_requests(), Map.keys(answers))

    if map_size(pending) == 0 do
      {:ok, Result.text(JSON.encode!(answers))}
    else
      suspend(context, pending, %{"phase" => "parallel", "answers" => answers})
    end
  end

  defp finish_parallel({:cancelled, response}, _context), do: cancelled(response)
  defp finish_parallel({:error, error}, _context), do: {:error, error}

  defp parallel_requests, do: %{"name" => field("name"), "color" => field("color")}

  defp consume(context, id, request, state, complete) do
    case Elicitation.response(context, id, request) do
      :missing -> suspend(context, %{id => request}, state)
      {:ok, response} -> complete.(response)
      {:error, error} -> {:error, error}
    end
  end

  defp cancelled(%{"action" => action}) do
    {:ok, Result.text("Input request #{action}; no operation performed")}
  end

  defp suspend(context, requests, state) do
    {:ok,
     Result.input_required(
       input_requests: requests,
       request_state: State.seal(state, context, state_options())
     )}
  end

  # Stateful workflows require a verified token before consuming any answer.
  # The basic, prompt, resource, and URL previews intentionally need no state.
  defp state(%{request_state: nil, input_responses: responses}) when map_size(responses) == 0,
    do: {:ok, nil}

  defp state(%{request_state: nil}), do: invalid_state()
  defp state(context), do: State.open(context.request_state, context, state_options())

  defp invalid_state,
    do: {:error, Error.invalid_params("Invalid or missing fixture request state")}

  defp state_options do
    [secret: Application.fetch_env!(:mcp_ex, :conformance_mrtr_secret), principal: nil, ttl: 300]
  end
end

defmodule MCPEx.Conformance.MRTR.Basic do
  @moduledoc false
  use MCP.Tool,
    name: "test_input_required_result_elicitation",
    description: "Elicits a name before returning a read-only greeting"

  alias MCPEx.Conformance.MRTR.Workflow
  @impl true
  def call(_arguments, context), do: Workflow.greeting(context)
end

defmodule MCPEx.Conformance.MRTR.RequestState do
  @moduledoc false
  use MCP.Tool,
    name: "test_input_required_result_request_state",
    description: "Validates signed request state before reporting confirmation"

  alias MCPEx.Conformance.MRTR.Workflow
  @impl true
  def call(_arguments, context), do: Workflow.confirmation(context)
end

defmodule MCPEx.Conformance.MRTR.TamperedState do
  @moduledoc false
  use MCP.Tool,
    name: "test_input_required_result_tampered_state",
    description: "Rejects tampered or request-mismatched confirmation state"

  alias MCPEx.Conformance.MRTR.Workflow
  @impl true
  def call(_arguments, context), do: Workflow.confirmation(context)
end

defmodule MCPEx.Conformance.MRTR.MultiRound do
  @moduledoc false
  use MCP.Tool,
    name: "test_input_required_result_multi_round",
    description: "Elicits a name and color in separate signed-state rounds"

  alias MCPEx.Conformance.MRTR.Workflow
  @impl true
  def call(_arguments, context), do: Workflow.multi_round(context)
end

defmodule MCPEx.Conformance.MRTR.ParallelForms do
  @moduledoc false
  use MCP.Tool,
    name: "test_input_required_result_parallel_forms",
    description: "Collects parallel form answers with signed partial progress"

  alias MCPEx.Conformance.MRTR.Workflow
  @impl true
  def call(_arguments, context), do: Workflow.parallel_forms(context)
end

defmodule MCPEx.Conformance.MRTR.URL do
  @moduledoc false
  use MCP.Tool,
    name: "test_input_required_result_url_consent",
    description: "Previews URL consent without claiming external completion"

  alias MCPEx.Conformance.MRTR.Workflow
  @impl true
  def call(_arguments, context), do: Workflow.url_consent(context)
end

defmodule MCPEx.Conformance.MRTR.Prompt do
  @moduledoc false
  use MCP.Prompt,
    name: "test_input_required_result_prompt",
    description: "Elicits context before rendering a prompt"

  alias MCPEx.Conformance.MRTR.Workflow

  @impl true
  def render(_arguments, context) do
    Workflow.single(context, "user_context", Workflow.field("context"), fn
      %{"action" => "accept", "content" => %{"context" => value}} ->
        MCP.Result.prompt_get(MCP.Prompt.message(:user, MCP.Prompt.text(value)))

      %{"action" => action} ->
        MCP.Result.prompt_get(MCP.Prompt.message(:user, MCP.Prompt.text("Input #{action}")))
    end)
  end
end

defmodule MCPEx.Conformance.MRTR.Resource do
  @moduledoc false
  # Keep the external runner's alphabetically first-resource cache probe on an
  # ordinary static resource. This additional resource requires user input.
  use MCP.Resource,
    name: "input_required_preview",
    uri: "z-mrtr://input-required-preview",
    description: "Elicits context before returning a read-only resource preview"

  alias MCPEx.Conformance.MRTR.Workflow

  @impl true
  def read(%{"uri" => uri}, context) do
    Workflow.single(context, "user_context", Workflow.field("context"), fn
      %{"action" => "accept", "content" => %{"context" => value}} ->
        MCP.Result.resource_read(MCP.Resource.text(uri, value))

      %{"action" => action} ->
        MCP.Result.resource_read(MCP.Resource.text(uri, "Input #{action}"))
    end)
  end
end

defmodule MCPEx.Conformance.MRTR do
  @moduledoc false

  def tools do
    [
      MCPEx.Conformance.MRTR.Basic,
      MCPEx.Conformance.MRTR.RequestState,
      MCPEx.Conformance.MRTR.TamperedState,
      MCPEx.Conformance.MRTR.MultiRound,
      MCPEx.Conformance.MRTR.ParallelForms,
      MCPEx.Conformance.MRTR.URL
    ]
  end

  def prompts, do: [MCPEx.Conformance.MRTR.Prompt]
  def resources, do: [MCPEx.Conformance.MRTR.Resource]
end
