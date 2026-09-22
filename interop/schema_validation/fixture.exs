# Mixless, public APIs only. No test/support imports or external services.
project = Path.expand("../..", __DIR__)
ebin = System.get_env("MCP_EX_EBIN") || Path.join(project, "_build/dev/lib/mcp_ex/ebin")
true = Code.prepend_path(ebin)
{:ok, _applications} = Application.ensure_all_started(:mcp_ex)

defmodule SchemaFixture.Input do
  @moduledoc false
  alias MCP.Elicitation
  alias MCP.Result

  def resolve(context, complete) do
    request =
      Elicitation.form("Provide a preview label", %{
        "type" => "object",
        "properties" => %{"label" => %{"type" => "string"}},
        "required" => ["label"]
      })

    case Elicitation.response(context, "label", request) do
      :missing -> {:ok, Result.input_required(input_requests: %{"label" => request})}
      {:ok, %{"action" => "accept", "content" => %{"label" => label}}} -> {:ok, complete.(label)}
      {:ok, %{"action" => action}} -> {:ok, complete.(action)}
      {:error, error} -> {:error, error}
    end
  end
end

defmodule SchemaFixture.Tool do
  @moduledoc false
  use MCP.Tool,
    name: "schema_preview",
    description: "Produces ordinary, input-required, and error preview results"

  input_schema(%{
    "type" => "object",
    "properties" => %{"mode" => %{"type" => "string"}}
  })

  @impl true
  def call(%{"mode" => "progress"}, context) do
    for value <- [0, 50, 100] do
      :ok = MCP.Progress.report(context, value, total: 100, message: "Schema stage #{value}")
    end

    {:ok, MCP.Result.text("schema-progress-ok")}
  end

  def call(%{"mode" => "mrtr"}, context),
    do: SchemaFixture.Input.resolve(context, &MCP.Result.text/1)

  def call(%{"mode" => "domain_error"}, _context),
    do: {:ok, MCP.Result.error("Preview unavailable")}

  def call(%{"mode" => "protocol_error"}, _context),
    do: {:error, MCP.Error.invalid_params("Invalid preview")}

  def call(_arguments, _context), do: {:ok, MCP.Result.text("schema-preview-ok")}
end

defmodule SchemaFixture.Resource do
  @moduledoc false
  use MCP.Resource,
    name: "schema_text",
    uri: "schema://text",
    description: "A read-only text resource",
    mime_type: "text/plain"

  @impl true
  def read(%{"uri" => uri}, _context),
    do: {:ok, MCP.Result.resource_read(MCP.Resource.text(uri, "schema-resource-ok"))}
end

defmodule SchemaFixture.InputResource do
  @moduledoc false
  use MCP.Resource,
    name: "schema_input",
    uri: "schema://input",
    description: "A read-only input-required resource"

  @impl true
  def read(%{"uri" => uri}, context) do
    SchemaFixture.Input.resolve(context, &MCP.Result.resource_read(MCP.Resource.text(uri, &1)))
  end
end

defmodule SchemaFixture.Template do
  @moduledoc false
  use MCP.Resource,
    name: "schema_template",
    uri_template: "schema://item/{id}",
    description: "A read-only URI-template resource"

  @impl true
  def read(%{"uri" => uri}, _context),
    do: {:ok, MCP.Result.resource_read(MCP.Resource.text(uri, "schema-template-ok"))}
end

defmodule SchemaFixture.Prompt do
  @moduledoc false
  use MCP.Prompt,
    name: "schema_prompt",
    description: "An optionally interactive prompt with completion",
    arguments: [%{"name" => "mode", "description" => "plain or mrtr"}],
    completion_arguments: ["mode"]

  @impl true
  def render(%{"mode" => "mrtr"}, context), do: SchemaFixture.Input.resolve(context, &result/1)
  def render(_arguments, _context), do: {:ok, result("schema-prompt-ok")}

  @impl true
  def complete(%MCP.Completion{value: value}, _context) do
    values = Enum.filter(["mrtr", "plain"], &String.starts_with?(&1, value))
    {:ok, MCP.Result.completion(values, total: length(values), has_more: false)}
  end

  defp result(label), do: MCP.Result.prompt_get(MCP.Prompt.message(:user, MCP.Prompt.text(label)))
end

defmodule SchemaFixture.Source do
  @moduledoc false
  @behaviour MCP.Subscription.Source
  alias MCP.Subscription.Event

  @impl true
  def open(filter, _context, _options) do
    {:ok, agent} =
      Agent.start_link(fn ->
        [Event.tools_list_changed(), Event.resource_updated("schema://text")]
      end)

    {:ok, filter, agent}
  end

  @impl true
  def next(agent, _options) do
    Agent.get_and_update(agent, fn
      [event | rest] -> {{:ok, event}, rest}
      [] -> {:closed, []}
    end)
  end

  @impl true
  def close(agent, _reason, _options) do
    if Process.alive?(agent), do: Agent.stop(agent)
    :ok
  end
end

defmodule SchemaFixture.Server do
  @moduledoc false
  use MCP.Server,
    name: "wire-schema-fixture",
    version: "1.0.0",
    protocols: [MCP.Protocol.V2026_07_28],
    capabilities: %{
      "tools" => %{"listChanged" => true},
      "resources" => %{"subscribe" => true},
      "prompts" => %{},
      "completions" => %{}
    },
    subscription_source: SchemaFixture.Source

  tool(SchemaFixture.Tool)
  resource(SchemaFixture.Resource)
  resource(SchemaFixture.InputResource)
  resource(SchemaFixture.Template)
  prompt(SchemaFixture.Prompt)
end

defmodule SchemaFixture.Direct do
  @moduledoc false
  alias MCP.Subscription

  def serve(runtime) do
    Enum.each(IO.stream(:stdio, :line), fn line ->
      case dispatch(runtime, JSON.decode!(line)) do
        {:ok, message} -> emit(message)
        {:stream, subscription} -> stream(subscription)
      end
    end)
  end

  # This JSON-lines direct adapter owns its sink exactly like a transport. The
  # core dispatch stays synchronous in the worker; the owner acknowledges each
  # report only after serializing and writing its notification.
  defp dispatch(runtime, raw) do
    sink = MCP.Progress.sink(self())
    transport = %MCP.Transport.Context{transport: :direct, metadata: %{progress_sink: sink}}
    task = Task.async(fn -> MCP.Server.dispatch(runtime, raw, transport) end)

    try do
      await_dispatch(task, MCP.Progress.state(sink))
    after
      MCP.Progress.close(sink)
      if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
    end
  end

  defp await_dispatch(task, state) do
    receive do
      {:"$gen_call", from, {:mcp_progress, _reference, report}} ->
        case MCP.Progress.accept(state, from, report) do
          {:ok, notification, next_state} ->
            emit(notification)
            MCP.Progress.reply(from, report, :ok)
            await_dispatch(task, next_state)

          {:error, reason} ->
            MCP.Progress.reply(from, report, {:error, reason})
            await_dispatch(task, state)
        end

      {reference, outcome} when reference == task.ref ->
        Process.demonitor(reference, [:flush])
        outcome

      {:DOWN, reference, :process, _pid, reason} when reference == task.ref ->
        raise "direct fixture worker failed: #{inspect(reason)}"
    after
      8_000 -> raise "direct fixture dispatch timed out"
    end
  end

  defp stream(subscription) do
    {:ok, acknowledgement} = Subscription.acknowledgement(subscription)
    emit(acknowledgement)
    {worker, monitor} = Subscription.start_worker(subscription, self())

    try do
      drain(subscription, worker)
    after
      Subscription.close(subscription, :complete)
      Subscription.stop_worker(worker, monitor)
    end
  end

  defp drain(subscription, worker) do
    Subscription.continue(worker)

    receive do
      {:mcp_subscription, ^worker, {:ok, event}} ->
        {:ok, notification} = Subscription.notification(subscription, event)
        emit(notification)
        drain(subscription, worker)

      {:mcp_subscription, ^worker, :closed} ->
        {:ok, completion} = Subscription.completion(subscription)
        emit(completion)
    after
      5_000 -> raise "subscription fixture did not complete"
    end
  end

  defp emit(message), do: IO.puts(JSON.encode!(message))
end

runtime = SchemaFixture.Server.runtime()

case System.argv() do
  ["--direct"] ->
    SchemaFixture.Direct.serve(runtime)

  ["--stdio"] ->
    MCP.Transport.Stdio.serve(runtime)

  ["--http"] ->
    {:ok, listener} = MCP.Transport.StreamableHTTP.Server.start_link(runtime: runtime, port: 0)
    IO.puts(JSON.encode!(%{"url" => MCP.Transport.StreamableHTTP.Server.url(listener)}))
    _input = IO.read(:stdio, :eof)
    :ok = GenServer.stop(listener)

  _arguments ->
    raise "usage: elixir fixture.exs --direct|--stdio|--http"
end
