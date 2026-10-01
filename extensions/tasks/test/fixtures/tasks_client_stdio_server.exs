# A Tasks server on stdio for Snodo.Extensions.Tasks.ClientTest. It runs the
# package's test tools with a Memory store, and a subscription source that
# sends each requested task's current status and then ends the stream.
#
# With `--stall METHOD MS`, the store's authorization of each METHOD request
# takes MS milliseconds, so the request stalls.
defmodule SnodoTest.TasksClientStdio.Source do
  @moduledoc false
  @behaviour Snodo.Subscription.Source

  alias Snodo.Extensions.Tasks
  alias Snodo.Extensions.Tasks.Snapshot
  alias Snodo.Extensions.Tasks.Store

  @impl true
  def open(filter, context, store) do
    events =
      filter
      |> Map.get("taskIds", [])
      |> Enum.flat_map(&current_event(store, context, &1))

    {:ok, queue} = Agent.start_link(fn -> events end)
    {:ok, filter, queue}
  end

  @impl true
  def next(queue, _store) do
    Agent.get_and_update(queue, fn
      [event | rest] -> {{:ok, event}, rest}
      [] -> {:closed, []}
    end)
  end

  @impl true
  def close(queue, _reason, _store) do
    if Process.alive?(queue), do: Agent.stop(queue)
    :ok
  end

  defp current_event(store, context, task_id) do
    with {:ok, access} <- Store.authorize(store, context, {:get, task_id}),
         {:ok, %Snapshot{} = snapshot} <- Store.get(store, task_id, access) do
      [Tasks.status_event(snapshot.task)]
    else
      _unknown_or_inaccessible -> []
    end
  end
end

alias Snodo.Extensions.Tasks.Runner
alias Snodo.Extensions.Tasks.Store.Memory

scope =
  case System.argv() do
    ["--stall", method, ms] ->
      fn context ->
        if context.request_method == method, do: Process.sleep(String.to_integer(ms))
        :shared
      end

    [] ->
      :shared
  end

{:ok, store} = Memory.start_link(scope: scope)
{:ok, runner} = Runner.start_link(store: {Memory, store})

runtime =
  SnodoTest.TasksTestSupport.runtime(store, runner, self(),
    subscription_source: {SnodoTest.TasksClientStdio.Source, {Memory, store}}
  )

:ok = Snodo.Transport.Stdio.serve(runtime)
