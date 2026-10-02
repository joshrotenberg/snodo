defmodule Snodo.Component.Wrap.Timeout do
  @moduledoc """
  Bounds one component callback with a supervised task.

  `timeout: 5_000` is the default. On expiry, the task is stopped and the
  component returns a defined failure. The callback runs in a task process,
  so its `self()` is different from the request process. The task is linked to
  its request owner and stops if that process ends.
  """

  @behaviour Snodo.Component.Wrap

  alias Snodo.Component.Wrap

  @default_timeout 5_000

  @doc false
  def validate_options!(options, env) do
    timeout = Keyword.get(options, :timeout, @default_timeout)

    unless Keyword.keys(options) -- [:timeout] == [] and is_integer(timeout) and timeout > 0 do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "timeout wrapper requires a positive :timeout in milliseconds"
    end

    :ok
  end

  @doc "Runs the next callback in a bounded supervised task."
  @impl true
  def call(context, arguments, next, options) do
    timeout = Keyword.get(options, :timeout, @default_timeout)
    kind = Keyword.fetch!(options, :kind)

    case start_task(fn -> next.(context, arguments) end) do
      {:ok, task} -> wait_task(task, timeout, kind)
      :error -> Wrap.reject(kind, "Component timeout worker unavailable")
    end
  end

  defp start_task(work) do
    task =
      Task.Supervisor.async(Snodo.Component.Wrap.Tasks, fn ->
        try do
          {:completed, work.()}
        rescue
          _error -> :failed
        catch
          _kind, _reason -> :failed
        end
      end)

    {:ok, task}
  rescue
    _error -> :error
  catch
    :exit, _reason -> :error
  end

  defp wait_task(task, timeout, kind) do
    case Task.yield(task, timeout) do
      {:ok, {:completed, result}} ->
        result

      {:ok, :failed} ->
        Wrap.reject(kind, "Component callback failed")

      {:exit, _reason} ->
        Wrap.reject(kind, "Component callback failed")

      nil ->
        _shutdown = Task.shutdown(task, :brutal_kill)
        Wrap.reject(kind, "Component timed out")
    end
  end
end
