defmodule MCP.Extensions.Tasks do
  @moduledoc """
  SEP-2663 Tasks extension for MCP `2026-07-28`.

  Tasks remains outside the core protocol catalog. The extension owns its three
  top-level methods and uses the generic extension middleware seam to augment
  selected `tools/call` operations. Store and runner processes are supplied by
  the application through extension options and are never started implicitly.

  A runtime installs the extension with application policy, for example:

      extensions: [
        {MCP.Extensions.Tasks,
         store: {MCP.Extensions.Tasks.Store.Memory, MyApp.TaskStore},
         runner: MyApp.TaskRunner,
         task_support: %{"slow_job" => :optional, "durable_job" => :required}}
      ]

  `:optional` tools execute as tasks when the client declares the extension and
  fall back to ordinary synchronous execution otherwise. `:required` tools
  return `-32021` when the per-request capability is absent. A policy value may
  also be an arity-2 function receiving `(params, context)`, allowing a server
  to decide per invocation.
  """

  @behaviour MCP.Extension

  alias MCP.Cancellation
  alias MCP.Context
  alias MCP.Envelope
  alias MCP.Error
  alias MCP.Extension.Method
  alias MCP.Extensions.Tasks.Event
  alias MCP.Extensions.Tasks.ExecutionContext
  alias MCP.Extensions.Tasks.RetryPolicy
  alias MCP.Extensions.Tasks.Runner
  alias MCP.Extensions.Tasks.Snapshot
  alias MCP.Extensions.Tasks.Store
  alias MCP.Extensions.Tasks.Task, as: ProtocolTask
  alias MCP.Extensions.Tasks.Work
  alias MCP.Result
  alias MCP.Subscription.Event, as: SubscriptionEvent
  alias MCP.Transport.Policy

  @id "io.modelcontextprotocol/tasks"
  @version "2026-07-28"
  @task_methods ["tasks/get", "tasks/update", "tasks/cancel"]
  @subscription_id_key "io.modelcontextprotocol/subscriptionId"

  @impl true
  def id, do: @id

  @impl true
  def methods do
    [
      Method.new!(
        protocol_version: @version,
        name: "tasks/get",
        operation: :tasks_get
      ),
      Method.new!(
        protocol_version: @version,
        name: "tasks/update",
        operation: :tasks_update
      ),
      Method.new!(
        protocol_version: @version,
        name: "tasks/cancel",
        operation: :tasks_cancel
      )
    ]
  end

  @impl true
  def negotiate(%{} = client_settings, %{} = server_settings) do
    if map_size(client_settings) == 0 and map_size(server_settings) == 0 do
      {:ok, %{}}
    else
      {:error, Error.invalid_params("The Tasks extension defines no settings")}
    end
  end

  @impl true
  def validate_operation(:tasks_get, params, %Context{}), do: validate_task_id(params)

  def validate_operation(:tasks_cancel, params, %Context{}), do: validate_task_id(params)

  def validate_operation(:tasks_update, params, %Context{}) do
    with :ok <- validate_task_id(params) do
      case Map.fetch(params, "inputResponses") do
        {:ok, responses} when is_map(responses) ->
          validate_input_responses(responses)

        _missing_or_invalid ->
          {:error, Error.invalid_params("tasks/update requires an inputResponses object")}
      end
    end
  end

  @impl true
  def dispatch(:tasks_get, %{"taskId" => task_id}, %Context{} = context) do
    with {:ok, store} <- fetch_store(context),
         {:ok, access} <- authorize(store, context, {:get, task_id}),
         {:ok, snapshot} <- fetch_task(store, task_id, access) do
      {:ok, Result.raw(snapshot.task)}
    end
  end

  def dispatch(
        :tasks_update,
        %{"taskId" => task_id, "inputResponses" => responses},
        %Context{} = context
      ) do
    with {:ok, store} <- fetch_store(context),
         {:ok, access} <- authorize(store, context, {:update, task_id}),
         {:ok, runner} <- fetch_runner(context),
         :ok <- normalize_runner_mutation(Runner.update(runner, task_id, responses, access)) do
      {:ok, Result.raw(%{})}
    end
  end

  def dispatch(:tasks_cancel, %{"taskId" => task_id}, %Context{} = context) do
    with {:ok, store} <- fetch_store(context),
         {:ok, access} <- authorize(store, context, {:cancel, task_id}),
         {:ok, runner} <- fetch_runner(context),
         :ok <- normalize_runner_mutation(Runner.cancel(runner, task_id, access)) do
      {:ok, Result.raw(%{})}
    end
  end

  @impl true
  def shape_result(:tasks_get, %Result{kind: :raw, value: %ProtocolTask{} = task}, %Context{}) do
    ProtocolTask.detailed_result(task)
  end

  def shape_result(operation, %Result{}, %Context{})
      when operation in [:tasks_update, :tasks_cancel] do
    %{"resultType" => "complete"}
  end

  def shape_result(_operation, %Result{}, %Context{}), do: %{"resultType" => "complete"}

  @impl true
  def shape_error(%Error{} = error, %Context{}), do: Error.to_json_rpc(error)

  @doc false
  @impl true
  def subscription_filter(requested_filter, %Context{} = context) do
    case Map.fetch(requested_filter, "taskIds") do
      :error ->
        {:ok, %{}}

      {:ok, task_ids} when is_list(task_ids) ->
        contribute_task_ids(task_ids, context)

      {:ok, _invalid} ->
        {:error, Error.invalid_params("subscriptions/listen taskIds must be a list")}
    end
  end

  @doc false
  @impl true
  def shape_subscription_event(
        %SubscriptionEvent{kind: :extension, payload: %ProtocolTask{} = task} = event,
        subscription_id,
        %Context{}
      ) do
    unless task_selected?(event.selector, task.id) do
      raise ArgumentError, "Tasks subscription event selector does not match its payload"
    end

    metadata = Map.put(event.metadata, @subscription_id_key, subscription_id)

    params =
      task
      |> ProtocolTask.notification_params()
      |> Map.put("_meta", metadata)

    %{"jsonrpc" => "2.0", "method" => "notifications/tasks", "params" => params}
  end

  def shape_subscription_event(%SubscriptionEvent{}, _subscription_id, %Context{}) do
    raise ArgumentError, "Tasks subscription events require a protocol Task payload"
  end

  @doc false
  @impl true
  def missing_capability_error(method, %Context{}) when method in @task_methods do
    missing_capability_error()
  end

  @doc false
  @impl true
  def transport_policy(%Envelope{method: method}, %Policy{} = base_policy)
      when method in @task_methods do
    %{
      base_policy
      | required_headers: Enum.uniq(base_policy.required_headers ++ ["mcp-name"]),
        mirrored_headers:
          Map.put(base_policy.mirrored_headers, "mcp-name", %{
            path: ["params", "taskId"],
            encoding: :base64_sentinel
          })
    }
  end

  @doc false
  @impl true
  def around_dispatch({:tools_call, name} = operation, params, %Context{} = context, next)
      when is_binary(name) and is_map(params) and is_function(next, 1) do
    task_context = put_request_params(context, params)

    with {:ok, decision} <- task_decision(name, params, task_context) do
      dispatch_decision(decision, operation, params, task_context, next)
    end
  end

  def around_dispatch(_operation, _params, %Context{} = context, next)
      when is_function(next, 1) do
    next.(context)
  end

  @doc "Returns true when this request negotiated the Tasks extension."
  @spec negotiated?(Context.t()) :: boolean()
  def negotiated?(%Context{} = context), do: Map.has_key?(context.extensions, @id)

  @doc "Builds a protocol-neutral `notifications/tasks` status event for an application source."
  @spec status_event(ProtocolTask.t(), keyword()) :: SubscriptionEvent.t()
  def status_event(%ProtocolTask{} = task, opts \\ []) when is_list(opts) do
    task = ProtocolTask.validate!(task)

    SubscriptionEvent.extension(
      @id,
      %{"taskIds" => [task.id]},
      task,
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  @doc "Returns the full request params visible to a task-aware tool."
  @spec request_params(Context.t()) :: map()
  def request_params(%Context{} = context) do
    context
    |> task_options()
    |> Map.get(:request_params, %{})
  end

  @doc "Returns input responses supplied on a pre-task MRTR retry."
  @spec input_responses(Context.t()) :: map()
  def input_responses(%Context{} = context) do
    context
    |> request_params()
    |> Map.get("inputResponses", %{})
  end

  @doc "Returns the stable idempotency key for the current task execution."
  @spec execution_id(Context.t()) :: String.t() | nil
  def execution_id(%Context{} = context) do
    context
    |> task_options()
    |> Map.get(:execution_id)
  end

  @doc """
  Suspends the current Tasks worker until a matching `tasks/update` arrives.

  The key must be unique for the lifetime of the task. The request is exposed
  verbatim in `tasks/get.inputRequests`; callers receive the matching response.
  """
  @spec await_input(Context.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def await_input(%Context{} = context, key, request)
      when is_binary(key) and is_map(request) do
    options = task_options(context)

    with task_id when is_binary(task_id) <- Map.get(options, :task_id),
         runner when not is_nil(runner) <- Map.get(options, :runner),
         {:ok, execution_token} <- Cancellation.normalize(context.cancellation) do
      Runner.await_input(runner, task_id, key, request, execution_token)
    else
      _not_in_task -> {:error, :not_in_task}
    end
  end

  @doc "Generates an unguessable, URL-safe task identifier."
  @spec generate_id() :: String.t()
  def generate_id do
    24
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp dispatch_decision(:sync, _operation, _params, context, next), do: next.(context)

  defp dispatch_decision(:optional, operation, params, context, next) do
    if negotiated?(context),
      do: create_task(operation, params, context, next, %{}),
      else: next.(context)
  end

  defp dispatch_decision(:required, operation, params, context, next) do
    if negotiated?(context),
      do: create_task(operation, params, context, next, %{}),
      else: {:error, missing_capability_error()}
  end

  defp dispatch_decision({mode, task_opts}, operation, params, context, next)
       when mode in [:optional, :required] and (is_list(task_opts) or is_map(task_opts)) do
    if negotiated?(context) do
      create_task(operation, params, context, next, normalize_options(task_opts))
    else
      case mode do
        :optional -> next.(context)
        :required -> {:error, missing_capability_error()}
      end
    end
  end

  defp dispatch_decision(other, _operation, _params, _context, _next) do
    {:error, Error.internal("Tasks policy returned an invalid decision", other)}
  end

  defp create_task({:tools_call, name} = operation, params, context, next, task_overrides) do
    options = task_options(context)

    with {:ok, store} <- fetch_store(context),
         {:ok, runner} <- fetch_runner(context),
         {:ok, id} <- generate_task_id(options),
         {:ok, now} <- read_clock(Map.get(options, :clock, &ProtocolTask.timestamp/0)),
         {:ok, task} <- new_task(id, now, options, task_overrides),
         {:ok, work} <-
           build_work(id, name, params, context, Map.merge(options, task_overrides)),
         {:ok, access} <- authorize(store, context, {:create, id}),
         {:ok, snapshot} <- normalize_store_create(Store.create(store, task, work, access)),
         :ok <- start_task(runner, snapshot, operation, context, next) do
      {:ok, Result.wire(ProtocolTask.creation_result(snapshot.task))}
    end
  end

  defp start_task(runner, snapshot, operation, context, next) do
    task_context =
      context
      |> put_task_runtime(snapshot.task.id, snapshot.work.idempotency_key, runner)
      |> ExecutionContext.detach()

    work = fn %Cancellation{} = cancellation ->
      execute_task(operation, %{task_context | cancellation: cancellation}, next)
    end

    case Runner.start_task(runner, snapshot, work) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, Error.internal("Task runner rejected work", reason)}
    end
  end

  defp execute_task(operation, task_context, next) do
    case next.(task_context) do
      {:ok, %Result{} = result} ->
        try do
          wire = task_context.protocol.shape_result(operation, result, task_context)
          {:completed, wire}
        rescue
          exception ->
            error = Error.internal("Task result shaping failed", {exception, __STACKTRACE__})
            {:failed, Error.to_json_rpc(error), error.message}
        end

      {:error, %Error{} = error} ->
        {:failed, Error.to_json_rpc(error), error.message}

      other ->
        error = Error.internal("Task continuation returned an invalid result", other)
        {:failed, Error.to_json_rpc(error), error.message}
    end
  end

  defp new_task(id, now, options, overrides) do
    task =
      ProtocolTask.new!(
        id: id,
        created_at: now,
        ttl_ms: Map.get(overrides, :ttl_ms, Map.get(options, :ttl_ms, 3_600_000)),
        poll_interval_ms:
          Map.get(overrides, :poll_interval_ms, Map.get(options, :poll_interval_ms, 250)),
        status_message: Map.get(overrides, :status_message, "Task accepted")
      )

    {:ok, task}
  rescue
    exception -> {:error, Error.internal("Invalid task configuration", exception)}
  end

  defp task_decision(name, params, context) do
    support = task_options(context) |> Map.get(:task_support, %{})
    value = if is_map(support), do: Map.get(support, name, :sync), else: :sync

    decision = if is_function(value, 2), do: value.(params, context), else: value

    {:ok, decision}
  rescue
    exception -> {:error, Error.internal("Tasks policy raised", {exception, __STACKTRACE__})}
  catch
    kind, reason ->
      {:error, Error.internal("Tasks policy terminated", {kind, reason, __STACKTRACE__})}
  end

  defp put_request_params(context, params) do
    update_task_options(context, &Map.put(&1, :request_params, params))
  end

  defp put_task_runtime(context, task_id, execution_id, runner) do
    update_task_options(context, fn options ->
      options
      |> Map.drop([:store, :task_support, :id_generator, :clock, :work_builder, :retry_policy])
      |> Map.put(:task_id, task_id)
      |> Map.put(:execution_id, execution_id)
      |> Map.put(:runner, runner)
    end)
  end

  defp update_task_options(%Context{} = context, update) do
    current = task_options(context)
    options = Map.put(context.extension_options, @id, update.(current))
    %{context | extension_options: options}
  end

  defp task_options(%Context{} = context) do
    context.extension_options
    |> Map.get(@id, %{})
    |> normalize_options()
  end

  defp normalize_options(options) when is_list(options), do: Map.new(options)
  defp normalize_options(options) when is_map(options), do: options
  defp normalize_options(_invalid), do: %{}

  defp fetch_store(context) do
    case Map.fetch(task_options(context), :store) do
      {:ok, store} ->
        try do
          {:ok, Store.validate_ref!(store)}
        rescue
          exception -> {:error, Error.internal("Tasks store is misconfigured", exception)}
        end

      :error ->
        {:error, Error.internal("Tasks extension requires a :store option")}
    end
  end

  defp fetch_runner(context) do
    case Map.fetch(task_options(context), :runner) do
      {:ok, runner} -> {:ok, runner}
      :error -> {:error, Error.internal("Tasks extension requires a :runner option")}
    end
  end

  defp authorize(store, context, action) do
    case Store.authorize(store, context, action) do
      {:ok, access} -> {:ok, access}
      {:error, :unauthorized} -> {:error, authorization_error(action)}
      {:error, reason} -> {:error, Error.internal("Task authorization failed", reason)}
    end
  end

  defp fetch_task(store, task_id, access) do
    case Store.get(store, task_id, access) do
      {:ok, %Snapshot{} = snapshot} -> {:ok, snapshot}
      :not_found -> {:error, unknown_task_error()}
      {:error, reason} -> {:error, Error.internal("Task store lookup failed", reason)}
    end
  end

  defp normalize_store_create({:ok, %Snapshot{} = snapshot}), do: {:ok, snapshot}

  defp normalize_store_create({:error, reason}),
    do: {:error, Error.internal("Task creation failed", reason)}

  defp normalize_runner_mutation(:ok), do: :ok
  defp normalize_runner_mutation(:not_found), do: {:error, unknown_task_error()}

  defp normalize_runner_mutation({:error, reason}),
    do: {:error, Error.internal("Task mutation failed", reason)}

  defp authorization_error({:create, _task_id}),
    do: Error.internal("Task creation was not authorized")

  defp authorization_error({_action, _task_id}), do: unknown_task_error()

  defp generate_task_id(options) do
    generator = Map.get(options, :id_generator, &generate_id/0)

    case generator.() do
      id when is_binary(id) and id != "" -> {:ok, id}
      invalid -> {:error, Error.internal("Task id generator returned an invalid id", invalid)}
    end
  rescue
    exception -> {:error, Error.internal("Task id generator raised", exception)}
  end

  defp build_work(task_id, name, params, context, options) do
    arguments = Map.get(params, "arguments", %{})

    result =
      case Map.get(options, :work_builder) do
        nil -> Work.tool_call(task_id, name, arguments)
        builder when is_function(builder, 4) -> builder.(task_id, name, arguments, context)
        invalid -> {:error, {:invalid_work_builder, invalid}}
      end

    case normalize_built_work(result, task_id) do
      {:ok, work} -> configure_retry_policy(work, Map.get(options, :retry_policy))
      {:error, _reason} = error -> error
    end
  rescue
    exception ->
      {:error, Error.internal("Task work builder raised", {exception, __STACKTRACE__})}
  catch
    kind, reason ->
      {:error, Error.internal("Task work builder terminated", {kind, reason, __STACKTRACE__})}
  end

  defp normalize_built_work({:ok, %Work{} = work}, task_id), do: validate_work(work, task_id)
  defp normalize_built_work(%Work{} = work, task_id), do: validate_work(work, task_id)

  defp normalize_built_work({:error, reason}, _task_id),
    do: {:error, Error.internal("Task work could not be serialized", reason)}

  defp normalize_built_work(invalid, _task_id),
    do: {:error, Error.internal("Task work builder returned an invalid value", invalid)}

  defp configure_retry_policy(work, nil), do: {:ok, work}

  defp configure_retry_policy(work, %RetryPolicy{} = policy) do
    case Work.put_retry_policy(work, policy) do
      {:ok, configured} -> {:ok, configured}
      {:error, reason} -> {:error, Error.internal("Invalid task retry policy", reason)}
    end
  end

  defp configure_retry_policy(work, delays_ms) when is_list(delays_ms) do
    case RetryPolicy.new(delays_ms) do
      {:ok, policy} -> configure_retry_policy(work, policy)
      {:error, reason} -> {:error, Error.internal("Invalid task retry policy", reason)}
    end
  end

  defp configure_retry_policy(_work, invalid),
    do: {:error, Error.internal("Invalid task retry policy", invalid)}

  defp validate_work(%Work{} = work, task_id) do
    case Work.validate(work) do
      :ok when work.idempotency_key == task_id ->
        {:ok, work}

      :ok ->
        {:error,
         Error.internal(
           "Task work idempotency key must match its task id",
           :idempotency_key_mismatch
         )}

      {:error, reason} ->
        {:error, Error.internal("Task work could not be serialized", reason)}
    end
  end

  defp read_clock(clock) when is_function(clock, 0) do
    case clock.() do
      timestamp when is_binary(timestamp) -> {:ok, timestamp}
      invalid -> {:error, Error.internal("Task clock returned an invalid timestamp", invalid)}
    end
  rescue
    exception -> {:error, Error.internal("Task clock raised", exception)}
  end

  defp read_clock(_invalid),
    do: {:error, Error.internal("Task clock must be an arity-0 function")}

  defp validate_task_id(params) do
    case Map.fetch(params, "taskId") do
      {:ok, task_id} when is_binary(task_id) and task_id != "" -> :ok
      _missing_or_invalid -> {:error, Error.invalid_params("A non-empty taskId is required")}
    end
  end

  defp validate_input_responses(responses) do
    case Event.input_responses_accepted(responses) do
      {:ok, _event} -> :ok
      {:error, _reason} -> {:error, Error.invalid_params("inputResponses is invalid")}
    end
  end

  defp validate_task_ids(task_ids) do
    if Enum.all?(task_ids, &(is_binary(&1) and &1 != "")),
      do: :ok,
      else: {:error, Error.invalid_params("taskIds must contain non-empty strings")}
  end

  defp contribute_task_ids(task_ids, context) do
    with :ok <- validate_task_ids(task_ids),
         :ok <- require_negotiated_subscription(context),
         {:ok, accepted} <- authorize_task_ids(task_ids, context) do
      if accepted == [], do: {:ok, %{}}, else: {:ok, %{"taskIds" => accepted}}
    end
  end

  defp task_selected?(%{"taskIds" => task_ids}, task_id) when is_list(task_ids) do
    task_id in task_ids
  end

  defp task_selected?(_selector, _task_id), do: false

  defp require_negotiated_subscription(context) do
    if negotiated?(context), do: :ok, else: {:error, missing_capability_error()}
  end

  defp authorize_task_ids(task_ids, context) do
    case fetch_store(context) do
      {:ok, store} -> collect_authorized_task_ids(task_ids, store, context)
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp collect_authorized_task_ids(task_ids, store, context) do
    task_ids
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn task_id, {:ok, accepted} ->
      case authorized_task?(store, task_id, context) do
        {:ok, true} -> {:cont, {:ok, [task_id | accepted]}}
        {:ok, false} -> {:cont, {:ok, accepted}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
    |> reverse_accepted_task_ids()
  end

  defp reverse_accepted_task_ids({:ok, accepted}), do: {:ok, Enum.reverse(accepted)}
  defp reverse_accepted_task_ids({:error, %Error{} = error}), do: {:error, error}

  defp authorized_task?(store, task_id, context) do
    case Store.authorize(store, context, {:get, task_id}) do
      {:ok, access} ->
        case Store.get(store, task_id, access) do
          {:ok, %Snapshot{}} -> {:ok, true}
          :not_found -> {:ok, false}
          {:error, reason} -> {:error, Error.internal("Task store lookup failed", reason)}
        end

      {:error, :unauthorized} ->
        {:ok, false}

      {:error, reason} ->
        {:error, Error.internal("Task authorization failed", reason)}
    end
  end

  defp missing_capability_error do
    %Error{
      code: -32_021,
      message: "Missing required client capability",
      kind: :extension,
      data: %{
        "requiredCapabilities" => %{
          "extensions" => %{@id => %{}}
        }
      }
    }
  end

  defp unknown_task_error, do: Error.invalid_params("Unknown or inaccessible taskId")
end
