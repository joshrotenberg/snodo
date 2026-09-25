# Public API fixture with deterministic cancellation coordination, no sleeps.
project = Path.expand("../..", __DIR__)
ebin = System.get_env("SNODO_EBIN") || Path.join(project, "_build/dev/lib/snodo/ebin")
true = Code.prepend_path(ebin)
{:ok, _applications} = Application.ensure_all_started(:snodo)

defmodule ProgressFixture.Control do
  @moduledoc false
  use GenServer

  def start_link, do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def track, do: GenServer.call(__MODULE__, {:track, self()})
  def completed, do: GenServer.call(__MODULE__, :completed)
  def await_stopped, do: GenServer.call(__MODULE__, :await_stopped, 15_000)
  def gate(operation), do: GenServer.call(__MODULE__, {:gate, operation, self()})

  def acknowledge(operation, value),
    do: GenServer.call(__MODULE__, {:acknowledge, operation, value})

  @impl true
  def init(nil),
    do: {:ok, %{monitor: nil, stopped: false, completed: false, waiters: [], gates: %{}}}

  @impl true
  def handle_call({:track, pid}, _from, state) do
    {:reply, :ok, %{state | monitor: Process.monitor(pid)}}
  end

  def handle_call({:gate, operation, pid}, _from, state) do
    {:reply, :ok, put_in(state, [:gates, operation], pid)}
  end

  def handle_call({:acknowledge, operation, value}, _from, state) do
    send(Map.fetch!(state.gates, operation), {:progress_ack, value})
    {:reply, :ok, state}
  end

  def handle_call(:completed, _from, state), do: {:reply, :ok, %{state | completed: true}}

  def handle_call(:await_stopped, _from, %{stopped: true} = state) do
    {:reply, %{"stopped" => true, "completed" => state.completed}, state}
  end

  def handle_call(:await_stopped, from, state) do
    {:noreply, %{state | waiters: [from | state.waiters]}}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{monitor: monitor} = state) do
    Enum.each(
      state.waiters,
      &GenServer.reply(&1, %{"stopped" => true, "completed" => state.completed})
    )

    {:noreply, %{state | stopped: true, waiters: []}}
  end
end

defmodule ProgressFixture.Tool do
  @moduledoc false
  use Snodo.Tool,
    name: "progress_preview",
    description: "Reports progress before a selected outcome"

  @impl true
  def call(%{"mode" => "slow"}, context) do
    :ok = ProgressFixture.Control.track()
    :ok = Snodo.Progress.report(context, 0, total: 100, message: "Parked until explicitly released")

    receive do
      :release ->
        :ok = Snodo.Progress.report(context, 100, total: 100, message: "Released")
        :ok = ProgressFixture.Control.completed()
        {:ok, Snodo.Result.text("must-not-complete-after-cancellation")}
    after
      15_000 -> raise "progress fixture was neither released nor cancelled"
    end
  end

  def call(arguments, context) do
    operation = Map.get(arguments, "operation")
    if operation, do: ProgressFixture.Control.gate(operation)

    for value <- [0, 50, 100] do
      :ok = Snodo.Progress.report(context, value, total: 100, message: "Stage #{value}")
      if operation, do: await_acknowledgement(value)
    end

    result(Map.get(arguments, "mode", "normal"), context)
  end

  defp await_acknowledgement(value) do
    receive do
      {:progress_ack, ^value} -> :ok
    after
      15_000 -> raise "client did not acknowledge the progress callback"
    end
  end

  defp result("domain_error", _context), do: {:ok, Snodo.Result.error("progress-domain-error")}

  defp result("protocol_error", _context),
    do: {:error, Snodo.Error.invalid_params("progress-protocol-error")}

  defp result("mrtr", context) do
    request =
      Snodo.Elicitation.form("Choose a preview label", %{
        "type" => "object",
        "properties" => %{"label" => %{"type" => "string"}},
        "required" => ["label"]
      })

    case Snodo.Elicitation.response(context, "label", request) do
      :missing ->
        {:ok, Snodo.Result.input_required(input_requests: %{"label" => request})}

      {:ok, %{"action" => "accept", "content" => %{"label" => label}}} ->
        {:ok, Snodo.Result.text(label)}

      {:ok, %{"action" => action}} ->
        {:ok, Snodo.Result.text(action)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp result(_mode, _context), do: {:ok, Snodo.Result.text("progress-ok")}
end

defmodule ProgressFixture.Acknowledge do
  @moduledoc false
  use Snodo.Tool, name: "progress_ack", description: "Releases exactly one controlled fixture stage"

  @impl true
  def call(%{"operation" => operation, "value" => value}, _context) do
    :ok = ProgressFixture.Control.acknowledge(operation, value)
    {:ok, Snodo.Result.text("acknowledged")}
  end
end

defmodule ProgressFixture.Status do
  @moduledoc false
  use Snodo.Tool, name: "progress_status", description: "Waits for the cancelled worker to stop"
  @impl true
  def call(_arguments, _context),
    do: {:ok, Snodo.Result.text(JSON.encode!(ProgressFixture.Control.await_stopped()))}
end

defmodule ProgressFixture.Server do
  @moduledoc false
  use Snodo.Server,
    name: "progress-fixture",
    version: "1.0.0",
    protocols: [Snodo.Protocol.V2026_07_28]

  tool(ProgressFixture.Tool)
  tool(ProgressFixture.Status)
  tool(ProgressFixture.Acknowledge)
end

{:ok, _control} = ProgressFixture.Control.start_link()
runtime = ProgressFixture.Server.runtime()

case System.argv() do
  ["--stdio"] ->
    Snodo.Transport.Stdio.serve(runtime)

  ["--http"] ->
    {:ok, listener} = Snodo.Transport.StreamableHTTP.Server.start_link(runtime: runtime, port: 0)
    IO.puts(JSON.encode!(%{"url" => Snodo.Transport.StreamableHTTP.Server.url(listener)}))
    _input = IO.read(:stdio, :eof)
    :ok = GenServer.stop(listener)

  _arguments ->
    raise "usage: elixir progress_fixture.exs --stdio|--http"
end
