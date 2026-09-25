defmodule Snodo.Extensions.Tasks.Store.Memory.Access do
  @moduledoc false

  @derive {Inspect, only: [:action]}
  @enforce_keys [:store_id, :scope, :action]
  defstruct [:store_id, :scope, :action]
end

defmodule Snodo.Extensions.Tasks.Store.Memory.Lease do
  @moduledoc false

  @derive {Inspect, only: [:task_id, :owner_id, :generation, :expires_at]}
  @enforce_keys [
    :store_id,
    :task_id,
    :owner_id,
    :token,
    :generation,
    :expires_at
  ]
  defstruct [:store_id, :task_id, :owner_id, :token, :generation, :expires_at]
end

defmodule Snodo.Extensions.Tasks.Store.Memory do
  @moduledoc """
  In-memory revisioned Tasks store intended for examples and tests.

  The optional `:scope` function derives an authorization scope from each
  request context. Scope mismatches deliberately return `:not_found`, so task
  existence is not disclosed across callers.

  This adapter implements the complete durable-store contract, including
  descriptors, fenced renewable claims, store-clock retry eligibility, recovery
  scans, and creation-based TTL reaping. Its records themselves remain
  volatile.
  """

  use GenServer

  @behaviour Snodo.Extensions.Tasks.Store

  alias Snodo.Context
  alias Snodo.Extensions.Tasks.Event
  alias Snodo.Extensions.Tasks.Snapshot
  alias Snodo.Extensions.Tasks.Store.Memory.Access
  alias Snodo.Extensions.Tasks.Store.Memory.Lease
  alias Snodo.Extensions.Tasks.Task, as: ProtocolTask
  alias Snodo.Extensions.Tasks.Transition
  alias Snodo.Extensions.Tasks.Work

  @worker_events [:input_requested, :retry_requested, :completed, :failed]
  @request_events %{update: :input_responses_accepted, cancel: :cancelled}

  @type server :: GenServer.server()
  @type history_entry :: %{
          event: Event.t(),
          committed_at: String.t(),
          revision: pos_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @impl Snodo.Extensions.Tasks.Store
  def authorize(store, %Context{} = context, action) do
    call(store, {:authorize, context, action})
  end

  @impl Snodo.Extensions.Tasks.Store
  def create(store, %ProtocolTask{} = task, %Work{} = work, access) do
    call(store, {:create, task, work, access})
  end

  @impl Snodo.Extensions.Tasks.Store
  def get(store, task_id, access) do
    call(store, {:get, task_id, access})
  end

  @impl Snodo.Extensions.Tasks.Store
  def worker_snapshot(store, task_id, lease) do
    call(store, {:worker_snapshot, task_id, lease})
  end

  @impl Snodo.Extensions.Tasks.Store
  def claim(store, task_id, owner_id, lease_ms) do
    call(store, {:claim, task_id, owner_id, lease_ms})
  end

  @impl Snodo.Extensions.Tasks.Store
  def claim_next(store, owner_id, lease_ms) do
    call(store, {:claim_next, owner_id, lease_ms})
  end

  @impl Snodo.Extensions.Tasks.Store
  def renew(store, lease, lease_ms) do
    call(store, {:renew, lease, lease_ms})
  end

  @impl Snodo.Extensions.Tasks.Store
  def release(store, lease) do
    call(store, {:release, lease})
  end

  @impl Snodo.Extensions.Tasks.Store
  def reap(store) do
    call(store, :reap)
  end

  @impl Snodo.Extensions.Tasks.Store
  def transition(store, task_id, expected_revision, %Event{} = event, authority) do
    call(store, {:transition, task_id, expected_revision, event, authority})
  end

  @doc false
  @spec history(server(), String.t(), term()) :: {:ok, [history_entry()]} | :not_found
  def history(store, task_id, access) when is_binary(task_id) do
    call(store, {:history, task_id, access})
  end

  defp call(store, message), do: GenServer.call(store, message, :infinity)

  @impl true
  def init(opts) do
    scope = Keyword.get(opts, :scope, fn _context -> :shared end)
    clock = Keyword.get(opts, :clock, &ProtocolTask.timestamp/0)

    unless is_function(scope, 1), do: raise(ArgumentError, ":scope must be an arity-1 function")
    unless is_function(clock, 0), do: raise(ArgumentError, ":clock must be an arity-0 function")

    {:ok, %{entries: %{}, scope: scope, clock: clock, store_id: make_ref()}}
  end

  @impl true
  def handle_call({:authorize, %Context{} = context, action}, _from, state) do
    case derive_scope(state.scope, context) do
      {:ok, scope} ->
        access = %Access{store_id: state.store_id, scope: scope, action: action}
        {:reply, {:ok, access}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:create, %ProtocolTask{} = task, %Work{} = work, access}, _from, state) do
    cond do
      not create_access?(access, state.store_id, task.id) ->
        {:reply, {:error, :unauthorized_action}, state}

      Map.has_key?(state.entries, task.id) ->
        {:reply, {:error, :already_exists}, state}

      true ->
        snapshot = Snapshot.new(task, work)

        entry = %{
          snapshot: snapshot,
          scope: access.scope,
          claim: nil,
          lease_generation: 0,
          seen_events: %{},
          history: []
        }

        {:reply, {:ok, snapshot}, put_in(state.entries[task.id], entry)}
    end
  rescue
    exception -> {:reply, {:error, {:invalid_task, exception}}, state}
  end

  def handle_call({:get, task_id, access}, _from, state) do
    reply =
      with {:ok, entry} <- fetch_entry(state.entries, task_id),
           :ok <- authorize_read(access, entry, state.store_id, task_id) do
        {:ok, entry.snapshot}
      else
        _unknown_or_inaccessible -> :not_found
      end

    {:reply, reply, state}
  end

  def handle_call({:worker_snapshot, task_id, lease}, _from, state) do
    reply =
      with {:ok, now} <- read_clock(state.clock),
           {:ok, entry} <- fetch_entry(state.entries, task_id),
           :ok <- authorize_worker(lease, entry, state.store_id, task_id, now) do
        {:ok, entry.snapshot}
      else
        :not_found -> :not_found
        {:error, reason} -> {:error, reason}
      end

    {:reply, reply, state}
  end

  def handle_call({:claim, task_id, owner_id, lease_ms}, _from, state) do
    with {:ok, now} <- read_clock(state.clock),
         {:ok, entry} <- fetch_entry(state.entries, task_id),
         {:ok, claimed, lease} <-
           claim_entry(entry, state.store_id, task_id, owner_id, lease_ms, now) do
      {:reply, {:ok, claimed.snapshot, lease}, put_in(state.entries[task_id], claimed)}
    else
      :not_found -> {:reply, :not_found, state}
      :unavailable -> {:reply, :unavailable, state}
      {:deferred, _remaining_ms} = deferred -> {:reply, deferred, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:claim_next, owner_id, lease_ms}, _from, state) do
    case read_clock(state.clock) do
      {:ok, now} ->
        case claim_next_entry(state, owner_id, lease_ms, now) do
          :empty ->
            {:reply, :empty, state}

          {:ok, task_id, claimed, lease} ->
            next = put_in(state.entries[task_id], claimed)
            {:reply, {:ok, claimed.snapshot, lease}, next}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:renew, lease, lease_ms}, _from, state) do
    with {:ok, now} <- read_clock(state.clock),
         {:ok, task_id} <- lease_task_id(lease),
         {:ok, entry} <- fetch_entry(state.entries, task_id),
         :ok <- authorize_worker(lease, entry, state.store_id, task_id, now),
         {:ok, expires_at} <- add_milliseconds(now, lease_ms) do
      renewed = %{lease | expires_at: expires_at}
      next_entry = %{entry | claim: claim_map(renewed)}
      {:reply, {:ok, renewed}, put_in(state.entries[task_id], next_entry)}
    else
      _stale_or_invalid -> {:reply, {:error, :stale_lease}, state}
    end
  end

  def handle_call({:release, lease}, _from, state) do
    with {:ok, task_id} <- lease_task_id(lease),
         {:ok, entry} <- fetch_entry(state.entries, task_id),
         true <- lease_identity_matches?(lease, entry, state.store_id, task_id) do
      next_entry = %{entry | claim: nil}
      {:reply, :ok, put_in(state.entries[task_id], next_entry)}
    else
      _stale_or_invalid -> {:reply, {:error, :stale_lease}, state}
    end
  end

  def handle_call(:reap, _from, state) do
    case read_clock(state.clock) do
      {:ok, now} ->
        reaped = expired_task_ids(state.entries, now)
        {:reply, {:ok, reaped}, %{state | entries: Map.drop(state.entries, reaped)}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:transition, task_id, expected_revision, %Event{} = event, authority},
        _from,
        state
      ) do
    case transition_entry(state, task_id, expected_revision, event, authority) do
      {:reply, reply} ->
        {:reply, reply, state}

      {:commit, reply, entry} ->
        {:reply, reply, put_in(state.entries[task_id], entry)}
    end
  end

  def handle_call({:history, task_id, access}, _from, state) do
    reply =
      with {:ok, entry} <- fetch_entry(state.entries, task_id),
           :ok <- authorize_read(access, entry, state.store_id, task_id) do
        {:ok, Enum.reverse(entry.history)}
      else
        _unknown_or_inaccessible -> :not_found
      end

    {:reply, reply, state}
  end

  defp transition_entry(state, task_id, expected_revision, event, authority) do
    with {:ok, now} <- read_clock(state.clock),
         {:ok, entry} <- fetch_entry(state.entries, task_id),
         :ok <- authorize_transition(authority, entry, state.store_id, task_id, event.kind, now),
         :ok <- Event.validate(event) do
      apply_or_replay(entry, expected_revision, event, now)
    else
      :not_found -> {:reply, :not_found}
      {:error, reason} -> {:reply, {:error, reason}}
    end
  end

  defp apply_or_replay(entry, expected_revision, event, now) do
    case Map.fetch(entry.seen_events, event.id) do
      {:ok, %{event: ^event, transition: accepted}} ->
        duplicate = %{accepted | outcome: :duplicate, snapshot: entry.snapshot}
        {:reply, {:ok, duplicate}}

      {:ok, _different_event} ->
        {:reply, {:error, :event_id_reused}}

      :error when entry.snapshot.revision != expected_revision ->
        {:reply, {:conflict, entry.snapshot}}

      :error ->
        apply_new_event(entry, event, now)
    end
  end

  defp apply_new_event(entry, event, now) do
    committed_at = monotonic_timestamp(entry.snapshot.task.last_updated_at, now)

    case Transition.apply(entry.snapshot, event, committed_at) do
      {:ok, %Transition{outcome: :unchanged} = transition} ->
        {:reply, {:ok, transition}}

      {:ok, %Transition{outcome: :applied} = transition} ->
        history_entry = %{
          event: event,
          committed_at: transition.committed_at,
          revision: transition.event_revision
        }

        next_entry = %{
          entry
          | snapshot: transition.snapshot,
            seen_events:
              Map.put(entry.seen_events, event.id, %{event: event, transition: transition}),
            history: [history_entry | entry.history]
        }

        {:commit, {:ok, transition}, next_entry}

      {:error, reason} ->
        {:reply, {:error, reason}}
    end
  end

  defp authorize_transition(
         {:request, %Access{} = access},
         entry,
         store_id,
         task_id,
         event_kind,
         _now
       ) do
    cond do
      access.store_id != store_id or access.scope != entry.scope ->
        :not_found

      access.action not in [{:update, task_id}, {:cancel, task_id}] ->
        {:error, :unauthorized_action}

      Map.get(@request_events, elem(access.action, 0)) != event_kind ->
        {:error, :unauthorized_action}

      true ->
        :ok
    end
  end

  defp authorize_transition(
         {:worker, lease},
         entry,
         store_id,
         task_id,
         event_kind,
         now
       ) do
    cond do
      authorize_worker(lease, entry, store_id, task_id, now) != :ok ->
        {:error, :stale_lease}

      event_kind not in @worker_events ->
        {:error, :unauthorized_action}

      true ->
        :ok
    end
  end

  defp authorize_transition(_authority, _entry, _store_id, _task_id, _event_kind, _now) do
    {:error, :unauthorized_action}
  end

  defp authorize_worker(%Lease{} = lease, entry, store_id, task_id, now) do
    if lease_identity_matches?(lease, entry, store_id, task_id) and
         timestamp_before?(now, lease.expires_at),
       do: :ok,
       else: {:error, :stale_lease}
  end

  defp authorize_worker(_lease, _entry, _store_id, _task_id, _now),
    do: {:error, :stale_lease}

  defp lease_identity_matches?(%Lease{} = lease, entry, store_id, task_id) do
    case entry.claim do
      %{} = claim ->
        lease.store_id == store_id and lease.task_id == task_id and
          lease.token == claim.token and lease.generation == claim.generation and
          lease.owner_id == claim.owner_id and lease.expires_at == claim.expires_at

      nil ->
        false
    end
  end

  defp authorize_read(%Access{} = access, entry, store_id, task_id) do
    allowed_action? =
      access.action in [{:get, task_id}, {:update, task_id}, {:cancel, task_id}]

    if access.store_id == store_id and access.scope == entry.scope and allowed_action?,
      do: :ok,
      else: :not_found
  end

  defp authorize_read(_access, _entry, _store_id, _task_id), do: :not_found

  defp create_access?(%Access{} = access, store_id, task_id) do
    access.store_id == store_id and access.action == {:create, task_id}
  end

  defp create_access?(_access, _store_id, _task_id), do: false

  defp claim_next_entry(state, owner_id, lease_ms, now) do
    state.entries
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while(:empty, fn {task_id, entry}, :empty ->
      case claim_entry(entry, state.store_id, task_id, owner_id, lease_ms, now) do
        {:ok, claimed, lease} -> {:halt, {:ok, task_id, claimed, lease}}
        :unavailable -> {:cont, :empty}
        {:deferred, _remaining_ms} -> {:cont, :empty}
        {:error, _reason} -> {:cont, :empty}
      end
    end)
  end

  defp claim_entry(entry, store_id, task_id, owner_id, lease_ms, now) do
    retry_availability = Snapshot.retry_availability(entry.snapshot, now)

    cond do
      ProtocolTask.terminal?(entry.snapshot.task) ->
        :unavailable

      is_nil(entry.snapshot.work) ->
        :unavailable

      match?({:deferred, _remaining_ms}, retry_availability) ->
        retry_availability

      retry_availability == :invalid ->
        {:error, :invalid_retry_availability}

      claim_live?(entry.claim, now) ->
        :unavailable

      true ->
        generation = entry.lease_generation + 1

        with {:ok, expires_at} <- add_milliseconds(now, lease_ms) do
          lease = new_lease(store_id, task_id, owner_id, generation, expires_at)
          claimed = %{entry | claim: claim_map(lease), lease_generation: generation}
          {:ok, claimed, lease}
        end
    end
  end

  defp claim_live?(nil, _now), do: false
  defp claim_live?(claim, now), do: timestamp_before?(now, claim.expires_at)

  defp new_lease(store_id, task_id, owner_id, generation, expires_at) do
    %Lease{
      store_id: store_id,
      task_id: task_id,
      owner_id: owner_id,
      token: :crypto.strong_rand_bytes(32),
      generation: generation,
      expires_at: expires_at
    }
  end

  defp claim_map(%Lease{} = lease) do
    %{
      token: lease.token,
      owner_id: lease.owner_id,
      generation: lease.generation,
      expires_at: lease.expires_at
    }
  end

  defp lease_task_id(%Lease{task_id: task_id}) when is_binary(task_id), do: {:ok, task_id}
  defp lease_task_id(_lease), do: {:error, :stale_lease}

  defp fetch_entry(entries, task_id) do
    case Map.fetch(entries, task_id) do
      {:ok, entry} -> {:ok, entry}
      :error -> :not_found
    end
  end

  defp expired_task_ids(entries, now) do
    entries
    |> Enum.filter(fn {_task_id, entry} -> expired_task?(entry.snapshot.task, now) end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp expired_task?(%ProtocolTask{ttl_ms: nil}, _now), do: false

  defp expired_task?(%ProtocolTask{} = task, now) do
    case add_milliseconds(task.created_at, task.ttl_ms) do
      {:ok, expires_at} -> not timestamp_before?(now, expires_at)
      {:error, _invalid_timestamp} -> false
    end
  end

  defp derive_scope(scope, context) do
    {:ok, scope.(context)}
  rescue
    exception -> {:error, {:scope_exception, exception, __STACKTRACE__}}
  catch
    kind, reason -> {:error, {:scope_exit, kind, reason, __STACKTRACE__}}
  end

  defp read_clock(clock) do
    case clock.() do
      now when is_binary(now) and now != "" ->
        if ProtocolTask.valid_timestamp?(now),
          do: {:ok, now},
          else: {:error, {:invalid_clock_value, now}}

      invalid ->
        {:error, {:invalid_clock_value, invalid}}
    end
  rescue
    exception -> {:error, {:clock_exception, exception, __STACKTRACE__}}
  end

  defp add_milliseconds(timestamp, milliseconds) do
    with {:ok, datetime, _offset} <- DateTime.from_iso8601(timestamp),
         advanced = datetime |> DateTime.add(milliseconds, :millisecond) |> DateTime.to_iso8601(),
         true <- ProtocolTask.valid_timestamp?(advanced) do
      {:ok, advanced}
    else
      _invalid_or_out_of_range -> {:error, :invalid_timestamp}
    end
  rescue
    ArgumentError -> {:error, :invalid_timestamp}
  end

  defp timestamp_before?(left, right) do
    with {:ok, left_at, _offset} <- DateTime.from_iso8601(left),
         {:ok, right_at, _offset} <- DateTime.from_iso8601(right) do
      DateTime.compare(left_at, right_at) == :lt
    else
      _invalid -> false
    end
  end

  defp monotonic_timestamp(previous, current) do
    if timestamp_before?(previous, current) do
      current
    else
      {:ok, advanced} = add_milliseconds(previous, 1)
      advanced
    end
  end
end
