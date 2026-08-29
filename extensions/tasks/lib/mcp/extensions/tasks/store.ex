defmodule MCP.Extensions.Tasks.Store do
  @moduledoc """
  Application-owned persistence contract for the Tasks extension.

  A request context crosses this boundary only through `authorize/3`. The
  resulting access value is opaque and deliberately scoped to one action. All
  mutations after that point are explicit, JSON-safe events guarded by an
  expected snapshot revision.

  Creation atomically persists the initial Task and its serializable work
  descriptor. Runners then acquire renewable, opaque claims. A lease can
  authorize only worker lifecycle events for its exact task and claim
  generation; it is not a substitute for fresh request authorization on
  `tasks/get`, `tasks/update`, or `tasks/cancel`.

  `claim_next/3` is the recovery seam. Expired or adapter-invalidated claims may
  be reacquired at a higher generation, fencing the previous worker. Both exact
  and recovery claims must also enforce the snapshot's persisted `retry_at`
  against store-authoritative time. Reaping removes the entire aggregate using
  the Task's creation-based TTL.

  Store references use `{module, state}` so implementations may be processes,
  database repositories, external job systems, or immutable test doubles.
  """

  alias MCP.Context
  alias MCP.Extensions.Tasks.Event
  alias MCP.Extensions.Tasks.Snapshot
  alias MCP.Extensions.Tasks.Task, as: ProtocolTask
  alias MCP.Extensions.Tasks.Transition
  alias MCP.Extensions.Tasks.Work

  @type ref :: {module(), term()}
  @type action ::
          {:create, String.t()}
          | {:get, String.t()}
          | {:update, String.t()}
          | {:cancel, String.t()}
  @type access :: term()
  @type worker_lease :: term()
  @type authority :: {:request, access()} | {:worker, worker_lease()}
  @type lookup_result :: {:ok, Snapshot.t()} | :not_found | {:error, term()}
  @type claim_result ::
          {:ok, Snapshot.t(), worker_lease()}
          | {:deferred, pos_integer()}
          | :unavailable
          | :not_found
          | {:error, term()}
  @type claim_next_result :: {:ok, Snapshot.t(), worker_lease()} | :empty | {:error, term()}
  @type transition_result ::
          {:ok, Transition.t()}
          | {:conflict, Snapshot.t()}
          | :not_found
          | {:error, term()}

  @callback authorize(store :: term(), Context.t(), action()) ::
              {:ok, access()} | {:error, term()}
  @callback create(store :: term(), ProtocolTask.t(), Work.t(), access()) ::
              {:ok, Snapshot.t()} | {:error, term()}
  @callback get(store :: term(), task_id :: String.t(), access()) :: lookup_result()
  @callback worker_snapshot(store :: term(), task_id :: String.t(), worker_lease()) ::
              lookup_result()
  @callback claim(
              store :: term(),
              task_id :: String.t(),
              owner_id :: String.t(),
              lease_ms :: pos_integer()
            ) :: claim_result()
  @callback claim_next(store :: term(), owner_id :: String.t(), lease_ms :: pos_integer()) ::
              claim_next_result()
  @callback renew(store :: term(), worker_lease(), lease_ms :: pos_integer()) ::
              {:ok, worker_lease()} | {:error, term()}
  @callback release(store :: term(), worker_lease()) :: :ok | {:error, term()}
  @callback reap(store :: term()) :: {:ok, [String.t()]} | {:error, term()}
  @callback transition(
              store :: term(),
              task_id :: String.t(),
              expected_revision :: non_neg_integer(),
              Event.t(),
              authority()
            ) :: transition_result()

  @doc "Acquires opaque, action-bound request access without retaining the context."
  @spec authorize(ref(), Context.t(), action()) :: {:ok, access()} | {:error, term()}
  def authorize({module, store}, %Context{} = context, {action, task_id} = requested)
      when is_atom(module) and action in [:create, :get, :update, :cancel] and
             is_binary(task_id) and task_id != "" do
    safe_call(module, :authorize, [store, context, requested], &normalize_authorize/1)
  end

  @spec create(ref(), ProtocolTask.t(), Work.t(), access()) ::
          {:ok, Snapshot.t()} | {:error, term()}
  def create({module, store}, %ProtocolTask{} = task, %Work{} = work, access)
      when is_atom(module) do
    safe_call(module, :create, [store, task, work, access], &normalize_create/1)
  end

  @spec get(ref(), String.t(), access()) :: lookup_result()
  def get({module, store}, task_id, access) when is_atom(module) and is_binary(task_id) do
    safe_call(module, :get, [store, task_id, access], &normalize_lookup/1)
  end

  @doc "Reads the current aggregate through an exact, live worker lease."
  @spec worker_snapshot(ref(), String.t(), worker_lease()) :: lookup_result()
  def worker_snapshot({module, store}, task_id, lease)
      when is_atom(module) and is_binary(task_id) do
    safe_call(module, :worker_snapshot, [store, task_id, lease], &normalize_lookup/1)
  end

  @doc "Atomically claims one exact nonterminal task whose retry delay is due."
  @spec claim(ref(), String.t(), String.t(), pos_integer()) :: claim_result()
  def claim({module, store}, task_id, owner_id, lease_ms)
      when is_atom(module) and is_binary(task_id) and task_id != "" and
             is_binary(owner_id) and owner_id != "" and is_integer(lease_ms) and lease_ms > 0 do
    safe_call(
      module,
      :claim,
      [store, task_id, owner_id, lease_ms],
      &normalize_claim/1
    )
  end

  @doc "Atomically claims the next available, retry-due recoverable task."
  @spec claim_next(ref(), String.t(), pos_integer()) :: claim_next_result()
  def claim_next({module, store}, owner_id, lease_ms)
      when is_atom(module) and is_binary(owner_id) and owner_id != "" and
             is_integer(lease_ms) and lease_ms > 0 do
    safe_call(module, :claim_next, [store, owner_id, lease_ms], &normalize_claim_next/1)
  end

  @doc "Extends a live worker claim without changing task state or revision."
  @spec renew(ref(), worker_lease(), pos_integer()) ::
          {:ok, worker_lease()} | {:error, term()}
  def renew({module, store}, lease, lease_ms)
      when is_atom(module) and is_integer(lease_ms) and lease_ms > 0 do
    safe_call(module, :renew, [store, lease, lease_ms], &normalize_renew/1)
  end

  @doc "Releases a matching claim so another runner may recover it immediately."
  @spec release(ref(), worker_lease()) :: :ok | {:error, term()}
  def release({module, store}, lease) when is_atom(module) do
    safe_call(module, :release, [store, lease], &normalize_release/1)
  end

  @doc "Deletes complete task aggregates whose creation-based TTL has elapsed."
  @spec reap(ref()) :: {:ok, [String.t()]} | {:error, term()}
  def reap({module, store}) when is_atom(module) do
    safe_call(module, :reap, [store], &normalize_reap/1)
  end

  @spec transition(
          ref(),
          String.t(),
          non_neg_integer(),
          Event.t(),
          authority()
        ) :: transition_result()
  def transition(
        {module, store},
        task_id,
        expected_revision,
        %Event{} = event,
        {kind, _opaque} = authority
      )
      when is_atom(module) and is_binary(task_id) and is_integer(expected_revision) and
             expected_revision >= 0 and kind in [:request, :worker] do
    safe_call(
      module,
      :transition,
      [store, task_id, expected_revision, event, authority],
      &normalize_transition/1
    )
  end

  @spec validate_ref!(term()) :: ref()
  def validate_ref!({module, _store} = ref) when is_atom(module) do
    required = [
      authorize: 3,
      create: 4,
      get: 3,
      worker_snapshot: 3,
      claim: 4,
      claim_next: 3,
      renew: 3,
      release: 2,
      reap: 1,
      transition: 5
    ]

    case Code.ensure_loaded(module) do
      {:module, ^module} -> :ok
      _missing -> raise ArgumentError, "task store module #{inspect(module)} could not be loaded"
    end

    Enum.each(required, fn {function, arity} ->
      unless function_exported?(module, function, arity) do
        raise ArgumentError,
              "task store module #{inspect(module)} does not export #{function}/#{arity}"
      end
    end)

    ref
  end

  def validate_ref!(_invalid) do
    raise ArgumentError, "task store must be a {module, state} tuple"
  end

  defp normalize_authorize({:ok, access}), do: {:ok, access}
  defp normalize_authorize({:error, reason}), do: {:error, reason}
  defp normalize_authorize(other), do: {:error, {:invalid_store_return, other}}

  defp normalize_create({:ok, %Snapshot{} = snapshot}), do: {:ok, snapshot}

  defp normalize_create({:error, reason}), do: {:error, reason}
  defp normalize_create(other), do: {:error, {:invalid_store_return, other}}

  defp normalize_lookup({:ok, %Snapshot{} = snapshot}), do: {:ok, snapshot}
  defp normalize_lookup(:not_found), do: :not_found
  defp normalize_lookup({:error, reason}), do: {:error, reason}
  defp normalize_lookup(other), do: {:error, {:invalid_store_return, other}}

  defp normalize_claim({:ok, %Snapshot{} = snapshot, lease}), do: {:ok, snapshot, lease}

  defp normalize_claim({:deferred, remaining_ms})
       when is_integer(remaining_ms) and remaining_ms > 0,
       do: {:deferred, remaining_ms}

  defp normalize_claim(:unavailable), do: :unavailable
  defp normalize_claim(:not_found), do: :not_found
  defp normalize_claim({:error, reason}), do: {:error, reason}
  defp normalize_claim(other), do: {:error, {:invalid_store_return, other}}

  defp normalize_claim_next({:ok, %Snapshot{} = snapshot, lease}),
    do: {:ok, snapshot, lease}

  defp normalize_claim_next(:empty), do: :empty
  defp normalize_claim_next({:error, reason}), do: {:error, reason}
  defp normalize_claim_next(other), do: {:error, {:invalid_store_return, other}}

  defp normalize_renew({:ok, lease}), do: {:ok, lease}
  defp normalize_renew({:error, reason}), do: {:error, reason}
  defp normalize_renew(other), do: {:error, {:invalid_store_return, other}}

  defp normalize_release(:ok), do: :ok
  defp normalize_release({:error, reason}), do: {:error, reason}
  defp normalize_release(other), do: {:error, {:invalid_store_return, other}}

  defp normalize_reap({:ok, task_ids}) when is_list(task_ids), do: {:ok, task_ids}
  defp normalize_reap({:error, reason}), do: {:error, reason}
  defp normalize_reap(other), do: {:error, {:invalid_store_return, other}}

  defp normalize_transition({:ok, %Transition{} = transition}), do: {:ok, transition}
  defp normalize_transition({:conflict, %Snapshot{} = snapshot}), do: {:conflict, snapshot}
  defp normalize_transition(:not_found), do: :not_found
  defp normalize_transition({:error, reason}), do: {:error, reason}
  defp normalize_transition(other), do: {:error, {:invalid_store_return, other}}

  defp safe_call(module, function, args, normalize) do
    module
    |> apply(function, args)
    |> normalize.()
  rescue
    exception -> {:error, {:store_exception, exception, __STACKTRACE__}}
  catch
    kind, reason -> {:error, {:store_exit, kind, reason, __STACKTRACE__}}
  end
end
