defmodule MCPEx.Conformance.Tasks.Greet do
  use MCP.Tool,
    name: "greet",
    description: "Returns a synchronous greeting"

  @impl true
  def call(arguments, _context) do
    name = Map.get(arguments, "name", "World")
    {:ok, MCP.Result.text("Hello, #{name}!")}
  end
end

defmodule MCPEx.Conformance.Tasks.SlowCompute do
  use MCP.Tool,
    name: "slow_compute",
    description: "Completes after a caller-selected delay"

  @impl true
  def call(arguments, _context) do
    seconds = Map.get(arguments, "seconds", 0)
    label = Map.get(arguments, "label", "work")

    if is_number(seconds) and seconds > 0 do
      Process.sleep(round(seconds * 1_000))
    end

    {:ok, MCP.Result.text("Completed #{label}")}
  end
end

defmodule MCPEx.Conformance.Tasks.FailingJob do
  use MCP.Tool,
    name: "failing_job",
    description: "Returns a tool-domain error from task work"

  @impl true
  def call(_arguments, _context), do: {:error, "The task job failed"}
end

defmodule MCPEx.Conformance.Tasks.ProtocolErrorJob do
  use MCP.Tool,
    name: "protocol_error_job",
    description: "Raises so the task records a protocol-level failure"

  @impl true
  def call(_arguments, _context), do: raise("intentional task fixture failure")
end

defmodule MCPEx.Conformance.Tasks.ConfirmDelete do
  use MCP.Tool,
    name: "confirm_delete",
    description: "Waits for one elicitation response inside a task"

  alias MCP.Extensions.Tasks

  @impl true
  def call(arguments, context) do
    filename = Map.get(arguments, "filename", "file.txt")

    request = %{
      "method" => "elicitation/create",
      "params" => %{
        "message" => "Delete #{filename}?",
        "requestedSchema" => %{
          "type" => "object",
          "properties" => %{"confirm" => %{"type" => "boolean"}},
          "required" => ["confirm"]
        }
      }
    }

    case Tasks.await_input(context, "confirm-delete", request) do
      {:ok, response} ->
        confirmed = get_in(response, ["content", "confirm"]) == true
        {:ok, MCP.Result.text("Delete confirmed: #{confirmed}")}

      {:error, reason} ->
        raise "task input failed: #{inspect(reason)}"
    end
  end
end

defmodule MCPEx.Conformance.Tasks.MultiInput do
  use MCP.Tool,
    name: "multi_input",
    description: "Waits for two independent task-scoped elicitation responses"

  alias MCP.Extensions.Tasks

  @impl true
  def call(_arguments, context) do
    first =
      Task.async(fn -> Tasks.await_input(context, "first-input", request("First input")) end)

    second =
      Task.async(fn -> Tasks.await_input(context, "second-input", request("Second input")) end)

    with {:ok, first_response} <- Task.await(first, :infinity),
         {:ok, second_response} <- Task.await(second, :infinity) do
      names = [input_name(first_response), input_name(second_response)]
      {:ok, MCP.Result.text("Inputs received: #{Enum.join(names, ", ")}")}
    else
      {:error, reason} -> raise "task input failed: #{inspect(reason)}"
    end
  end

  defp request(message) do
    %{
      "method" => "elicitation/create",
      "params" => %{
        "message" => message,
        "requestedSchema" => %{
          "type" => "object",
          "properties" => %{
            "name" => %{"type" => "string"},
            "confirm" => %{"type" => "boolean"}
          }
        }
      }
    }
  end

  defp input_name(response), do: get_in(response, ["content", "name"]) || "confirmed"
end

defmodule MCPEx.Conformance.Tasks.MRTRThenTask do
  use MCP.Tool,
    name: "test_tool_with_task",
    description: "Gathers MRTR input synchronously, then completes it as a task"

  alias MCP.Extensions.Tasks

  @impl true
  def call(_arguments, context) do
    case Tasks.input_responses(context) do
      responses when map_size(responses) == 0 ->
        {:ok,
         MCP.Result.wire(%{
           "resultType" => "input_required",
           "inputRequests" => %{
             "user_name" => %{
               "method" => "elicitation/create",
               "params" => %{
                 "message" => "What is your name?",
                 "requestedSchema" => %{
                   "type" => "object",
                   "properties" => %{"name" => %{"type" => "string"}},
                   "required" => ["name"]
                 }
               }
             }
           },
           "requestState" => "tasks-composition-round-1"
         })}

      responses ->
        response = Map.get(responses, "user_name") || responses |> Map.values() |> List.first()
        name = get_in(response || %{}, ["content", "name"]) || "unknown"
        {:ok, MCP.Result.text("Hello, #{name}; task completed")}
    end
  end
end

defmodule MCPEx.Conformance.Tasks do
  @moduledoc false

  alias MCP.Extensions.Tasks
  alias MCP.Extensions.Tasks.Runner
  alias MCP.Extensions.Tasks.Store.Memory

  @tools [
    MCPEx.Conformance.Tasks.Greet,
    MCPEx.Conformance.Tasks.SlowCompute,
    MCPEx.Conformance.Tasks.FailingJob,
    MCPEx.Conformance.Tasks.ProtocolErrorJob,
    MCPEx.Conformance.Tasks.ConfirmDelete,
    MCPEx.Conformance.Tasks.MultiInput,
    MCPEx.Conformance.Tasks.MRTRThenTask
  ]

  def tools, do: @tools

  def extension do
    {:ok, store} = Memory.start_link()
    store_ref = {Memory, store}
    {:ok, runner} = Runner.start_link(store: store_ref)

    {Tasks,
     store: store_ref,
     runner: runner,
     ttl_ms: 3_600_000,
     poll_interval_ms: 100,
     task_support: %{
       "slow_compute" => :optional,
       "failing_job" => :required,
       "protocol_error_job" => :required,
       "confirm_delete" => :optional,
       "multi_input" => :optional,
       "test_tool_with_task" => &composition_policy/2
     }}
  end

  def capabilities do
    %{
      "tools" => %{},
      "extensions" => %{Tasks.id() => %{}}
    }
  end

  defp composition_policy(params, _context) do
    if map_size(Map.get(params, "inputResponses", %{})) == 0, do: :sync, else: :required
  end
end
