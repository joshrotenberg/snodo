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
      SnodoTest.Conformance.Stateless.StreamingElicitation,
      SnodoTest.Conformance.Stateless.TriggerToolChange,
      SnodoTest.Conformance.Stateless.TriggerPromptChange
    ]
  end
end

defmodule SnodoTest.Conformance.Stateless.Logging do
  @moduledoc false

  # Snodo has no server logging API: notifications/message is deprecated in
  # 2026-07-28 and never sent, with or without a requested log level.
  use Snodo.Tool,
    name: "test_logging_tool",
    description: "Completes without logging; Snodo never sends notifications/message"

  @impl true
  def call(_arguments, _context), do: {:ok, Snodo.Result.text("Completed without logging")}
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
