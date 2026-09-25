# Package-local fixtures for the Tasks extension acceptance suite.
defmodule SnodoTest.TasksTestTools.Support do
  @moduledoc false

  alias Snodo.Extensions.Tasks

  def owner(context) do
    options = Map.fetch!(context.extension_options, Tasks.id())
    options = if is_list(options), do: Map.new(options), else: options
    Map.fetch!(options, :owner)
  end

  def input_request(message) do
    %{
      "method" => "elicitation/create",
      "params" => %{
        "message" => message,
        "requestedSchema" => %{
          "type" => "object",
          "properties" => %{"confirmed" => %{"type" => "boolean"}},
          "required" => ["confirmed"]
        }
      }
    }
  end
end

defmodule SnodoTest.TasksTestTools.Greet do
  use Snodo.Tool, name: "greet"

  @impl true
  def call(%{"name" => name}, _context), do: {:ok, Snodo.Result.text("Hello, #{name}!")}
end

defmodule SnodoTest.TasksTestTools.SlowCompute do
  use Snodo.Tool, name: "slow_compute"

  alias SnodoTest.TasksTestTools.Support

  @impl true
  def call(arguments, context) do
    label = Map.get(arguments, "label", "unlabelled")

    if Map.get(arguments, "block", false) do
      owner = Support.owner(context)
      send(owner, {:tasks_barrier_entered, label, self()})

      receive do
        {:tasks_release, ^label} -> :ok
      after
        5_000 -> raise "task test barrier timed out"
      end
    end

    {:ok, Snodo.Result.structured(%{"label" => label, "computed" => true})}
  end
end

defmodule SnodoTest.TasksTestTools.FailingJob do
  use Snodo.Tool, name: "failing_job"

  @impl true
  def call(_arguments, _context), do: {:error, "Actionable task failure"}
end

defmodule SnodoTest.TasksTestTools.ProtocolErrorJob do
  use Snodo.Tool, name: "protocol_error_job"

  # Raising is the point: the runner must isolate a job fault.
  @spec call(map(), Snodo.Context.t()) :: no_return()
  @impl true
  def call(_arguments, _context), do: raise("private task crash detail")
end

defmodule SnodoTest.TasksTestTools.DetachedContext do
  use Snodo.Tool, name: "detached_context"

  alias Snodo.Extensions.Tasks
  alias SnodoTest.TasksTestTools.Support

  @impl true
  def call(_arguments, context) do
    owner = Support.owner(context)
    send(owner, {:tasks_detached_ready, self()})

    receive do
      :inspect_detached -> send(owner, {:tasks_detached_observed, observation(context, owner)})
    after
      5_000 -> raise "detached context inspection timed out"
    end

    receive do
      :release_detached -> {:ok, Snodo.Result.structured(%{"detached" => true})}
    after
      5_000 -> raise "detached context release timed out"
    end
  end

  defp observation(context, owner) do
    transport = context.transport

    %{
      application_owner: owner,
      auth: context.auth,
      execution_id: Tasks.execution_id(context),
      request_id_nil?: is_nil(context.request_id),
      session_nil?: is_nil(context.session),
      progress_nil?: is_nil(context.progress),
      metadata_empty?: context.metadata == %{},
      transport: transport.transport,
      peer_nil?: is_nil(transport.peer),
      request_headers_empty?: transport.request_headers == %{},
      response_handle_nil?: is_nil(transport.response_handle),
      connection_ref_nil?: is_nil(transport.connection_ref),
      transport_metadata_empty?: transport.metadata == %{}
    }
  end
end

defmodule SnodoTest.TasksTestTools.InvalidRawResult do
  use Snodo.Tool, name: "invalid_raw_result"

  @impl true
  def call(_arguments, _context) do
    {:ok, Snodo.Result.raw(%{"nested" => %{"pid" => self()}})}
  end
end

defmodule SnodoTest.TasksTestTools.ConfirmDelete do
  use Snodo.Tool, name: "confirm_delete"

  alias Snodo.Extensions.Tasks
  alias SnodoTest.TasksTestTools.Support

  @impl true
  def call(_arguments, context) do
    with {:ok, response} <-
           Tasks.await_input(context, "confirmation", Support.input_request("Confirm delete")) do
      {:ok, Snodo.Result.structured(%{"confirmation" => response})}
    end
  end
end

defmodule SnodoTest.TasksTestTools.MultiInput do
  use Snodo.Tool, name: "multi_input"

  alias Snodo.Extensions.Tasks
  alias SnodoTest.TasksTestTools.Support

  @impl true
  def call(_arguments, context) do
    first =
      Task.async(fn ->
        Tasks.await_input(context, "first", Support.input_request("First confirmation"))
      end)

    second =
      Task.async(fn ->
        Tasks.await_input(context, "second", Support.input_request("Second confirmation"))
      end)

    with {:ok, first_response} <- Task.await(first, 5_000),
         {:ok, second_response} <- Task.await(second, 5_000) do
      {:ok,
       Snodo.Result.structured(%{
         "responses" => %{"first" => first_response, "second" => second_response}
       })}
    end
  end
end

defmodule SnodoTest.TasksTestTools.KeyReuse do
  use Snodo.Tool, name: "key_reuse"

  alias Snodo.Extensions.Tasks
  alias SnodoTest.TasksTestTools.Support

  @impl true
  def call(_arguments, context) do
    owner = Support.owner(context)

    with {:ok, first_response} <-
           Tasks.await_input(context, "one-shot", Support.input_request("One-time input")) do
      reuse = Tasks.await_input(context, "one-shot", Support.input_request("Reused input"))
      send(owner, {:tasks_key_reuse_result, reuse})

      {:ok,
       Snodo.Result.structured(%{
         "firstResponse" => first_response,
         "reuseRejected" => match?({:error, :duplicate_input_key}, reuse)
       })}
    end
  end
end

defmodule SnodoTest.TasksTestSupport do
  @moduledoc false

  alias Snodo.Extensions.Tasks
  alias Snodo.Extensions.Tasks.Store.Memory
  alias Snodo.Protocol.V2026_07_28
  alias Snodo.Router
  alias Snodo.Server
  alias Snodo.Server.Runtime
  alias Snodo.Transport.Context, as: TransportContext

  @extension_id "io.modelcontextprotocol/tasks"

  @tools [
    SnodoTest.TasksTestTools.Greet,
    SnodoTest.TasksTestTools.SlowCompute,
    SnodoTest.TasksTestTools.FailingJob,
    SnodoTest.TasksTestTools.ProtocolErrorJob,
    SnodoTest.TasksTestTools.DetachedContext,
    SnodoTest.TasksTestTools.InvalidRawResult,
    SnodoTest.TasksTestTools.ConfirmDelete,
    SnodoTest.TasksTestTools.MultiInput,
    SnodoTest.TasksTestTools.KeyReuse
  ]

  @task_support %{
    "greet" => :sync,
    "slow_compute" => :optional,
    "failing_job" => :required,
    "protocol_error_job" => :optional,
    "detached_context" => :optional,
    "invalid_raw_result" => :optional,
    "confirm_delete" => :optional,
    "multi_input" => :optional,
    "key_reuse" => :optional
  }

  def extension_id, do: @extension_id

  @spec runtime(term(), term(), pid(), keyword()) :: Runtime.t()
  def runtime(store, runner, owner, opts \\ []) do
    router = Enum.reduce(@tools, Router.new(), &Router.register_tool(&2, &1))

    extension_options = [
      store: {Memory, store},
      runner: runner,
      owner: owner,
      task_support: Keyword.get(opts, :task_support, @task_support),
      ttl_ms: 60_000,
      poll_interval_ms: 5,
      id_generator: fn ->
        "task-#{System.unique_integer([:monotonic, :positive])}"
      end
    ]

    extension_options =
      case Keyword.fetch(opts, :work_builder) do
        {:ok, builder} -> Keyword.put(extension_options, :work_builder, builder)
        :error -> extension_options
      end

    extension_options =
      case Keyword.fetch(opts, :retry_policy) do
        {:ok, retry_policy} -> Keyword.put(extension_options, :retry_policy, retry_policy)
        :error -> extension_options
      end

    runtime_options =
      [
        router: router,
        protocols: [V2026_07_28],
        extensions: [{Tasks, extension_options}],
        server_info: %{"name" => "tasks-test", "version" => "0.1.0"},
        capabilities: %{
          "tools" =>
            if(Keyword.get(opts, :tools_list_changed, false),
              do: %{"listChanged" => true},
              else: %{}
            ),
          "extensions" => %{@extension_id => %{}}
        }
      ]

    runtime_options =
      case Keyword.fetch(opts, :subscription_source) do
        {:ok, source} -> Keyword.put(runtime_options, :subscription_source, source)
        :error -> runtime_options
      end

    Runtime.new(runtime_options)
  end

  def request(id, method, params \\ %{}, opts \\ []) do
    client_capabilities =
      if Keyword.get(opts, :tasks, true) do
        %{"extensions" => %{@extension_id => %{}}}
      else
        %{}
      end

    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => Map.put(params, "_meta", V2026_07_28.request_metadata(client_capabilities))
    }
  end

  def call(runtime, id, name, arguments \\ %{}, opts \\ []) do
    dispatch(
      runtime,
      request(id, "tools/call", %{"name" => name, "arguments" => arguments}, opts),
      opts
    )
  end

  def get(runtime, id, task_id, opts \\ []) do
    dispatch(runtime, request(id, "tasks/get", %{"taskId" => task_id}, opts), opts)
  end

  def update(runtime, id, task_id, responses, opts \\ []) do
    dispatch(
      runtime,
      request(
        id,
        "tasks/update",
        %{"taskId" => task_id, "inputResponses" => responses},
        opts
      ),
      opts
    )
  end

  def cancel(runtime, id, task_id, opts \\ []) do
    dispatch(runtime, request(id, "tasks/cancel", %{"taskId" => task_id}, opts), opts)
  end

  def dispatch(runtime, raw, opts \\ []) do
    transport = Keyword.get(opts, :transport_context, %TransportContext{transport: :direct})

    transport =
      case Keyword.fetch(opts, :auth) do
        {:ok, auth} -> %{transport | metadata: Map.put(transport.metadata, :auth, auth)}
        :error -> transport
      end

    Server.dispatch(runtime, raw, transport)
  end

  def eventually_get(runtime, task_id, predicate, opts \\ [])
      when is_function(predicate, 1) do
    timeout = Keyword.get(opts, :timeout, 2_000)
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually_get(runtime, task_id, predicate, opts, deadline)
  end

  defp do_eventually_get(runtime, task_id, predicate, opts, deadline) do
    id = "poll-#{System.unique_integer([:monotonic, :positive])}"

    case get(runtime, id, task_id, opts) do
      {:ok, %{"result" => result}} = response ->
        if predicate.(result) do
          response
        else
          retry_get(runtime, task_id, predicate, opts, deadline, result)
        end

      other ->
        retry_get(runtime, task_id, predicate, opts, deadline, other)
    end
  end

  defp retry_get(runtime, task_id, predicate, opts, deadline, last) do
    if System.monotonic_time(:millisecond) >= deadline do
      raise ExUnit.AssertionError,
        message: "task #{task_id} did not reach expected state; last response: #{inspect(last)}"
    end

    Process.sleep(2)
    do_eventually_get(runtime, task_id, predicate, opts, deadline)
  end
end

defmodule SnodoTest.TasksSubscriptionHub do
  @moduledoc false
  use GenServer

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  def emit(hub, request_id, event), do: GenServer.call(hub, {:deliver, request_id, {:ok, event}})
  def complete(hub, request_id), do: GenServer.call(hub, {:deliver, request_id, :closed})

  @impl true
  def init(opts), do: {:ok, %{owner: Keyword.get(opts, :owner), subscriptions: %{}}}

  @impl true
  def handle_call({:open, request_id, filter}, _from, state) do
    token = make_ref()
    notify(state.owner, {:tasks_subscription_opened, request_id, filter})
    subscription = %{request_id: request_id, queue: :queue.new(), waiter: nil, closed?: false}
    {:reply, {:ok, filter, {self(), token}}, put_in(state, [:subscriptions, token], subscription)}
  end

  def handle_call({:next, token}, from, state) do
    subscription = get_in(state, [:subscriptions, token])

    case :queue.out(subscription.queue) do
      {{:value, value}, queue} ->
        {:reply, value, put_in(state, [:subscriptions, token, :queue], queue)}

      {:empty, _queue} when subscription.closed? ->
        {:reply, :closed, state}

      {:empty, _queue} ->
        {:noreply, put_in(state, [:subscriptions, token, :waiter], from)}
    end
  end

  def handle_call({:deliver, request_id, value}, _from, state) do
    case find_subscription(state.subscriptions, request_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      {token, %{waiter: waiter} = subscription} when not is_nil(waiter) ->
        GenServer.reply(waiter, value)
        subscription = %{subscription | waiter: nil, closed?: value == :closed}
        {:reply, :ok, put_in(state, [:subscriptions, token], subscription)}

      {token, subscription} when value == :closed ->
        {:reply, :ok, put_in(state, [:subscriptions, token], %{subscription | closed?: true})}

      {token, subscription} ->
        queued = %{subscription | queue: :queue.in(value, subscription.queue)}
        {:reply, :ok, put_in(state, [:subscriptions, token], queued)}
    end
  end

  def handle_call({:close, token, reason}, _from, state) do
    case Map.pop(state.subscriptions, token) do
      {nil, _subscriptions} ->
        {:reply, :ok, state}

      {subscription, subscriptions} ->
        if subscription.waiter, do: GenServer.reply(subscription.waiter, :closed)
        notify(state.owner, {:tasks_subscription_closed, subscription.request_id, reason})
        {:reply, :ok, %{state | subscriptions: subscriptions}}
    end
  end

  defp find_subscription(subscriptions, request_id) do
    Enum.find(subscriptions, fn {_token, subscription} ->
      subscription.request_id == request_id
    end)
  end

  defp notify(owner, message) when is_pid(owner), do: send(owner, message)
  defp notify(_owner, _message), do: :ok
end

defmodule SnodoTest.TasksSubscriptionSource do
  @moduledoc false
  @behaviour Snodo.Subscription.Source

  @impl true
  def open(filter, context, hub), do: GenServer.call(hub, {:open, context.request_id, filter})

  @impl true
  def next({hub, token}, _hub), do: GenServer.call(hub, {:next, token}, :infinity)

  @impl true
  def close({hub, token}, reason, _hub), do: GenServer.call(hub, {:close, token, reason})
end

defmodule SnodoTest.TasksTestInput do
  @moduledoc false

  def start_link do
    pid = spawn_link(fn -> loop(:queue.new(), nil, false) end)
    {:ok, pid}
  end

  def push(device, line) when is_binary(line), do: send(device, {:push, line})
  def eof(device), do: send(device, :eof)

  defp loop(queue, waiter, eof?) do
    receive do
      {:push, line} ->
        case waiter do
          {from, reply_as} ->
            io_reply(from, reply_as, line)
            loop(queue, nil, eof?)

          nil ->
            loop(:queue.in(line, queue), nil, eof?)
        end

      :eof ->
        if waiter && :queue.is_empty(queue) do
          {from, reply_as} = waiter
          io_reply(from, reply_as, :eof)
        else
          loop(queue, waiter, true)
        end

      {:io_request, from, reply_as, {:get_line, _encoding, _prompt}} ->
        case :queue.out(queue) do
          {{:value, line}, remaining} ->
            io_reply(from, reply_as, line)
            loop(remaining, nil, eof?)

          {:empty, _queue} when eof? ->
            io_reply(from, reply_as, :eof)

          {:empty, empty_queue} ->
            loop(empty_queue, {from, reply_as}, false)
        end

      {:io_request, from, reply_as, _unsupported} ->
        io_reply(from, reply_as, {:error, :enotsup})
        loop(queue, waiter, eof?)
    end
  end

  defp io_reply(to, reply_as, reply), do: send(to, {:io_reply, reply_as, reply})
end
