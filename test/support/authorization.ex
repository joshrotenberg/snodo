defmodule MCPEx.TestAuthorization.Policy do
  @moduledoc false
  @behaviour MCP.Authorization

  alias MCP.Authorization.Component
  alias MCP.Context
  alias MCP.Error

  @refusal_code -32_003

  @impl true
  def authorize(phase, %Component{} = component, %Context{} = context, options) do
    principal = principal(context)

    if MapSet.member?(allowed(options, principal), signature(component)) do
      :ok
    else
      audit(options, phase, principal, component, context)

      {:error,
       Error.authorization(@refusal_code, "Application policy refused #{label(component)}", %{
         "component" => label(component),
         "uri" => component.uri
       })}
    end
  end

  @doc "The refusal code this fixture policy uses; `mcp_ex` never chooses one."
  def refusal_code, do: @refusal_code

  defp principal(%Context{auth: %{"principal" => principal}}), do: principal
  defp principal(%Context{}), do: nil

  defp allowed(%{allowed: allowed}, principal), do: Map.get(allowed, principal, MapSet.new())

  defp audit(%{owner: owner}, :invocation, principal, component, context) when is_pid(owner) do
    send(owner, {:authorization_refused, principal, signature(component), context.request_method})
  end

  defp audit(%{owner: owner}, :discovery, principal, component, _context) when is_pid(owner) do
    send(owner, {:authorization_hidden, principal, signature(component)})
  end

  defp audit(_options, _phase, _principal, _component, _context), do: :ok

  defp signature(%Component{kind: kind, name: name}), do: {kind, name}
  defp label(%Component{kind: kind, name: name}), do: "#{kind}:#{name}"
end

defmodule MCPEx.TestAuthorization.DenyAll do
  @moduledoc false
  @behaviour MCP.Authorization

  @impl true
  def authorize(_phase, component, _context, _options) do
    {:error, MCP.Error.authorization(-32_004, "Denied #{component.name}")}
  end
end

defmodule MCPEx.TestAuthorization.Raising do
  @moduledoc false
  @behaviour MCP.Authorization

  # Raising is the point: a policy fault must not be mistaken for a refusal.
  # The spec states that so Dialyzer does not report it as an accidental
  # no_return.
  @spec authorize(
          MCP.Authorization.phase(),
          MCP.Authorization.Component.t(),
          MCP.Context.t(),
          term()
        ) :: no_return()
  @impl true
  def authorize(_phase, _component, _context, _options) do
    raise "private authorization policy detail"
  end
end

defmodule MCPEx.TestAuthorization.InvalidDecision do
  @moduledoc false
  @behaviour MCP.Authorization

  @impl true
  def authorize(_phase, _component, _context, _options), do: :maybe
end

defmodule MCPEx.TestAuthorization.NotAPolicy do
  @moduledoc false
  def authorize(_phase, _component), do: :ok
end

defmodule MCPEx.TestAuthorization.ProbeTool do
  @moduledoc false
  use MCP.Tool, name: "probe_tool"

  # Direct dispatch runs the handler in the calling test process, so a bare
  # send/2 proves whether the callback was reached at all.
  input_schema(%{
    "type" => "object",
    "properties" => %{"text" => %{"type" => "string"}},
    "required" => ["text"]
  })

  @impl true
  def call(%{"text" => text}, _context) do
    send(self(), {:probe, :tool_call})
    {:ok, MCP.Result.text(text)}
  end
end

defmodule MCPEx.TestAuthorization.ProbePrompt do
  @moduledoc false
  use MCP.Prompt,
    name: "probe_prompt",
    arguments: [%{"name" => "topic", "required" => true}],
    completion_arguments: ["topic"]

  @impl true
  def render(%{"topic" => topic}, _context) do
    send(self(), {:probe, :prompt_get})
    {:ok, MCP.Result.prompt_get(MCP.Prompt.message(:user, MCP.Prompt.text("About #{topic}.")))}
  end

  @impl true
  def complete(%MCP.Completion{argument: "topic"}, _context) do
    send(self(), {:probe, :prompt_complete})
    {:ok, MCP.Result.completion(["releases"])}
  end
end

defmodule MCPEx.TestAuthorization.ProbeResource do
  @moduledoc false
  use MCP.Resource, uri: "probe://static", name: "probe_static"

  @impl true
  def read(%{"uri" => uri}, _context) do
    send(self(), {:probe, :resource_read})
    {:ok, MCP.Result.resource_read(MCP.Resource.text(uri, "probe"))}
  end
end

defmodule MCPEx.TestAuthorization.ProbeTemplate do
  @moduledoc false
  use MCP.Resource,
    uri_template: "probe://items/{id}",
    name: "probe_item",
    completion_arguments: ["id"]

  @impl true
  def matches?(uri) when is_binary(uri), do: String.starts_with?(uri, "probe://items/")

  @impl true
  def read(%{"uri" => uri}, _context) do
    send(self(), {:probe, :template_read})
    {:ok, MCP.Result.resource_read(MCP.Resource.text(uri, "item"))}
  end

  @impl true
  def complete(%MCP.Completion{argument: "id"}, _context) do
    send(self(), {:probe, :template_complete})
    {:ok, MCP.Result.completion(["1"])}
  end
end
