# Diagnostic tools the official server-stateless scenario calls by name.

defmodule SnodoTest.Conformance.Stateless do
  @moduledoc false

  # The fixture server starts this hub before the listener; the runtime reads
  # list-changed events from it for subscriptions/listen.
  @hub SnodoTest.Conformance.SubscriptionHub

  def hub, do: @hub

  def tools do
    [
      SnodoTest.Conformance.Stateless.Logging,
      SnodoTest.Conformance.Stateless.MissingCapability,
      SnodoTest.Conformance.Stateless.StreamingElicitation,
      SnodoTest.Conformance.Stateless.TriggerToolChange,
      SnodoTest.Conformance.Stateless.TriggerPromptChange
    ]
  end
end

defmodule SnodoTest.Conformance.Stateless.MissingCapability do
  @moduledoc false

  # The scenario calls this with empty client capabilities and expects
  # -32021 naming sampling. The tool always asks for sampling; the dialect
  # refuses the result before it is sent when the client did not declare it.
  use Snodo.Tool,
    name: "test_missing_capability",
    description: "Requests sampling, which the dialect refuses unless the client declares it"

  alias SnodoTest.Conformance.MRTR.Workflow

  @impl true
  def call(_arguments, context), do: Workflow.capital(context)
end

defmodule SnodoTest.Conformance.Stateless.Logging do
  @moduledoc false

  # Logs at every level. A 2026-07-28 request without
  # `_meta["io.modelcontextprotocol/logLevel"]` must receive none of them.
  use Snodo.Tool,
    name: "test_logging_tool",
    description: "Logs at every level; a request without a log level receives none"

  @impl true
  def call(_arguments, context) do
    for level <- Snodo.Logging.levels() do
      :ok = Snodo.Logging.log(context, level, "#{level} message", logger: "conformance")
    end

    {:ok, Snodo.Result.text("Logged at every level")}
  end
end

defmodule SnodoTest.Conformance.Stateless.StreamingElicitation do
  @moduledoc false

  # An initialize-era server would send elicitation/create on the response
  # stream. A 2026-07-28 server returns the elicitation as input_required.
  use Snodo.Tool,
    name: "test_streaming_elicitation",
    description: "Elicits a name through input_required, never through a server request"

  alias SnodoTest.Conformance.MRTR.Workflow

  @impl true
  def call(_arguments, context), do: Workflow.greeting(context)
end

defmodule SnodoTest.Conformance.Stateless.TriggerToolChange do
  @moduledoc false
  use Snodo.Tool,
    name: "test_trigger_tool_change",
    description: "Publishes a tools list-changed event to subscriptions/listen streams"

  @impl true
  def call(_arguments, _context) do
    :ok = Snodo.Subscription.Hub.notify_tools_list_changed(SnodoTest.Conformance.Stateless.hub())
    {:ok, Snodo.Result.text("Published tools list_changed")}
  end
end

defmodule SnodoTest.Conformance.Stateless.TriggerPromptChange do
  @moduledoc false
  use Snodo.Tool,
    name: "test_trigger_prompt_change",
    description: "Publishes a prompts list-changed event to subscriptions/listen streams"

  @impl true
  def call(_arguments, _context) do
    :ok =
      Snodo.Subscription.Hub.notify_prompts_list_changed(SnodoTest.Conformance.Stateless.hub())

    {:ok, Snodo.Result.text("Published prompts list_changed")}
  end
end
