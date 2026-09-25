defmodule SnodoTest.TestAuthorization.Policy do
  @moduledoc false
  @behaviour Snodo.Authorization

  alias Snodo.Authorization.Component
  alias Snodo.Context
  alias Snodo.Error

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

  @doc "The refusal code this fixture policy uses; `snodo` never chooses one."
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

defmodule SnodoTest.TestAuthorization.DenyAll do
  @moduledoc false
  @behaviour Snodo.Authorization

  @impl true
  def authorize(_phase, component, _context, _options) do
    {:error, Snodo.Error.authorization(-32_004, "Denied #{component.name}")}
  end
end

defmodule SnodoTest.TestAuthorization.Raising do
  @moduledoc false
  @behaviour Snodo.Authorization

  # Raising is the point: a policy fault must not be mistaken for a refusal.
  # The spec states that so Dialyzer does not report it as an accidental
  # no_return.
  @spec authorize(
          Snodo.Authorization.phase(),
          Snodo.Authorization.Component.t(),
          Snodo.Context.t(),
          term()
        ) :: no_return()
  @impl true
  def authorize(_phase, _component, _context, _options) do
    raise "private authorization policy detail"
  end
end

defmodule SnodoTest.TestAuthorization.InvalidDecision do
  @moduledoc false

  # Deliberately not a conforming policy: it exports authorize/4 and returns
  # something the behaviour does not allow. Declaring the behaviour here would
  # only tell Dialyzer about the violation this fixture exists to reproduce at
  # runtime.
  def authorize(_phase, _component, _context, _options), do: :maybe
end

defmodule SnodoTest.TestAuthorization.NotAPolicy do
  @moduledoc false
  def authorize(_phase, _component), do: :ok
end

defmodule SnodoTest.TestAuthorization.ProbeTool do
  @moduledoc false
  use Snodo.Tool, name: "probe_tool"

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
    {:ok, Snodo.Result.text(text)}
  end
end

defmodule SnodoTest.TestAuthorization.ProbePrompt do
  @moduledoc false
  use Snodo.Prompt,
    name: "probe_prompt",
    arguments: [%{"name" => "topic", "required" => true}],
    completion_arguments: ["topic"]

  @impl true
  def render(%{"topic" => topic}, _context) do
    send(self(), {:probe, :prompt_get})

    {:ok,
     Snodo.Result.prompt_get(Snodo.Prompt.message(:user, Snodo.Prompt.text("About #{topic}.")))}
  end

  @impl true
  def complete(%Snodo.Completion{argument: "topic"}, _context) do
    send(self(), {:probe, :prompt_complete})
    {:ok, Snodo.Result.completion(["releases"])}
  end
end

defmodule SnodoTest.TestAuthorization.ProbeResource do
  @moduledoc false
  use Snodo.Resource, uri: "probe://static", name: "probe_static"

  @impl true
  def read(%{"uri" => uri}, _context) do
    send(self(), {:probe, :resource_read})
    {:ok, Snodo.Result.resource_read(Snodo.Resource.text(uri, "probe"))}
  end
end

defmodule SnodoTest.TestAuthorization.ProbeTemplate do
  @moduledoc false
  use Snodo.Resource,
    uri_template: "probe://items/{id}",
    name: "probe_item",
    completion_arguments: ["id"]

  @impl true
  def matches?(uri) when is_binary(uri), do: String.starts_with?(uri, "probe://items/")

  @impl true
  def read(%{"uri" => uri}, _context) do
    send(self(), {:probe, :template_read})
    {:ok, Snodo.Result.resource_read(Snodo.Resource.text(uri, "item"))}
  end

  @impl true
  def complete(%Snodo.Completion{argument: "id"}, _context) do
    send(self(), {:probe, :template_complete})
    {:ok, Snodo.Result.completion(["1"])}
  end
end
