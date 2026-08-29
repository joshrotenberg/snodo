defmodule MCP.Extensions.Tasks.Store.Dets.Access do
  @moduledoc false

  @derive {Inspect, only: [:action]}
  @enforce_keys [:store_id, :boot_epoch, :scope, :action]
  defstruct [:store_id, :boot_epoch, :scope, :action]
end

defmodule MCP.Extensions.Tasks.Store.Dets.Lease do
  @moduledoc false

  @derive {Inspect, only: [:task_id, :owner_id, :generation, :expires_at]}
  @enforce_keys [
    :store_id,
    :boot_epoch,
    :task_id,
    :owner_id,
    :token,
    :generation,
    :expires_at
  ]
  defstruct [
    :store_id,
    :boot_epoch,
    :task_id,
    :owner_id,
    :token,
    :generation,
    :expires_at
  ]
end

defmodule MCP.Extensions.Tasks.Store.Dets do
  @moduledoc """
  Local durable Tasks store backed by one DETS table.

  Every task aggregate is persisted as one versioned JSON binary. Applied
  transitions, claims, renewals, releases, creation, and reaping are synced to
  disk before their callers are acknowledged. A stable store UUID survives
  reopen, while a persisted boot epoch advances on every open. Consequently,
  leases from a prior store process are fenced immediately and their claims
  can be recovered without waiting for the old lease deadline. Exact and
  recovery claims also enforce persisted retry availability against this
  adapter's clock.

  `:path` is required. `:table` must be a caller-supplied atom when more than
  one adapter is open in the same BEAM; it defaults to this module name, which
  deliberately permits only one default-named table at a time. The optional
  `:scope` callback must return a JSON-safe value because its result is part of
  the durable authorization record.

  DETS is a local reference adapter, not a distributed database. The GenServer
  serializes operations in one BEAM, and DETS itself has a 2 GB file limit.
  """

  use GenServer

  @behaviour MCP.Extensions.Tasks.Store

  import Bitwise

  alias MCP.Context
  alias MCP.Extensions.Tasks.Event
  alias MCP.Extensions.Tasks.RetryPolicy
  alias MCP.Extensions.Tasks.Snapshot
  alias MCP.Extensions.Tasks.Store.Dets.Access
  alias MCP.Extensions.Tasks.Store.Dets.Lease
  alias MCP.Extensions.Tasks.Task, as: ProtocolTask
  alias MCP.Extensions.Tasks.Transition
  alias MCP.Extensions.Tasks.Work
  alias MCP.JSONValue

  @metadata_key {:metadata, "store"}
  @metadata_version 1
  @entry_version 1
  @uuid_pattern ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
  @worker_events [:input_requested, :retry_requested, :completed, :failed]
  @request_events %{update: :input_responses_accepted, cancel: :cancelled}

  @type server :: GenServer.server()
  @type history_entry :: %{
          event: Event.t(),
          committed_at: String.t(),
          revision: pos_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    path = Keyword.fetch!(opts, :path)
    table = Keyword.get(opts, :table, __MODULE__)

    unless is_binary(path) and path != "" do
      raise ArgumentError, ":path must be a non-empty path string"
    end

    unless is_atom(table) do
      raise ArgumentError, ":table must be a caller-supplied atom"
    end

    GenServer.start_link(
      __MODULE__,
      Keyword.put(opts, :table, table),
      Keyword.take(opts, [:name])
    )
  end

  @impl MCP.Extensions.Tasks.Store
  def authorize(store, %Context{} = context, action) do
    call(store, {:authorize, context, action})
  end

  @impl MCP.Extensions.Tasks.Store
  def create(store, %ProtocolTask{} = task, %Work{} = work, access) do
    call(store, {:create, task, work, access})
  end

  @impl MCP.Extensions.Tasks.Store
  def get(store, task_id, access) do
    call(store, {:get, task_id, access})
  end

  @impl MCP.Extensions.Tasks.Store
  def worker_snapshot(store, task_id, lease) do
    call(store, {:worker_snapshot, task_id, lease})
  end

  @impl MCP.Extensions.Tasks.Store
  def claim(store, task_id, owner_id, lease_ms) do
    call(store, {:claim, task_id, owner_id, lease_ms})
  end

  @impl MCP.Extensions.Tasks.Store
  def claim_next(store, owner_id, lease_ms) do
    call(store, {:claim_next, owner_id, lease_ms})
  end

  @impl MCP.Extensions.Tasks.Store
  def renew(store, lease, lease_ms) do
    call(store, {:renew, lease, lease_ms})
  end

  @impl MCP.Extensions.Tasks.Store
  def release(store, lease) do
    call(store, {:release, lease})
  end

  @impl MCP.Extensions.Tasks.Store
  def reap(store) do
    call(store, :reap)
  end

  @impl MCP.Extensions.Tasks.Store
  def transition(store, task_id, expected_revision, %Event{} = event, authority) do
    call(store, {:transition, task_id, expected_revision, event, authority})
  end

  @doc false
  @spec history(server(), String.t(), term()) ::
          {:ok, [history_entry()]} | :not_found | {:error, term()}
  def history(store, task_id, access) when is_binary(task_id) do
    call(store, {:history, task_id, access})
  end

  defp call(store, message), do: GenServer.call(store, message, :infinity)

  @impl true
  def init(opts) do
    scope = Keyword.get(opts, :scope, fn _context -> "shared" end)
    clock = Keyword.get(opts, :clock, &ProtocolTask.timestamp/0)
    table = Keyword.fetch!(opts, :table)
    path = opts |> Keyword.fetch!(:path) |> Path.expand()

    unless is_function(scope, 1), do: raise(ArgumentError, ":scope must be an arity-1 function")
    unless is_function(clock, 0), do: raise(ArgumentError, ":clock must be an arity-0 function")

    case open_store(table, path) do
      {:ok, metadata} ->
        {:ok,
         %{
           table: table,
           path: path,
           store_id: metadata.store_id,
           boot_epoch: metadata.boot_epoch,
           scope: scope,
           clock: clock
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:authorize, %Context{} = context, action}, _from, state) do
    case derive_scope(state.scope, context) do
      {:ok, scope} ->
        access = %Access{
          store_id: state.store_id,
          boot_epoch: state.boot_epoch,
          scope: scope,
          action: action
        }

        {:reply, {:ok, access}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:create, %ProtocolTask{} = task, %Work{} = work, access}, _from, state) do
    reply = create_entry(state, task, work, access)
    {:reply, reply, state}
  end

  def handle_call({:get, task_id, access}, _from, state) do
    reply =
      with {:ok, entry} <- fetch_entry(state.table, task_id),
           :ok <- authorize_read(access, entry, state, task_id) do
        {:ok, entry.snapshot}
      else
        :not_found -> :not_found
        {:error, {:corrupt_store, _key, _reason}} = error -> error
        _inaccessible -> :not_found
      end

    {:reply, reply, state}
  end

  def handle_call({:worker_snapshot, task_id, lease}, _from, state) do
    reply =
      with {:ok, now} <- read_clock(state.clock),
           {:ok, entry} <- fetch_entry(state.table, task_id),
           :ok <- authorize_worker(lease, entry, state, task_id, now) do
        {:ok, entry.snapshot}
      else
        :not_found -> :not_found
        {:error, reason} -> {:error, reason}
      end

    {:reply, reply, state}
  end

  def handle_call({:claim, task_id, owner_id, lease_ms}, _from, state) do
    reply =
      with {:ok, now} <- read_clock(state.clock),
           {:ok, entry} <- fetch_entry(state.table, task_id),
           {:ok, claimed, lease} <- claim_entry(entry, state, task_id, owner_id, lease_ms, now),
           :ok <- persist_entry(state.table, task_id, claimed) do
        {:ok, claimed.snapshot, lease}
      else
        :not_found -> :not_found
        :unavailable -> :unavailable
        {:deferred, _remaining_ms} = deferred -> deferred
        {:error, reason} -> {:error, reason}
      end

    {:reply, reply, state}
  end

  def handle_call({:claim_next, owner_id, lease_ms}, _from, state) do
    reply = claim_next_entry(state, owner_id, lease_ms)
    {:reply, reply, state}
  end

  def handle_call({:renew, lease, lease_ms}, _from, state) do
    reply = renew_claim(state, lease, lease_ms)
    {:reply, reply, state}
  end

  def handle_call({:release, lease}, _from, state) do
    reply = release_claim(state, lease)
    {:reply, reply, state}
  end

  def handle_call(:reap, _from, state) do
    reply = reap_expired(state)
    {:reply, reply, state}
  end

  def handle_call(
        {:transition, task_id, expected_revision, %Event{} = event, authority},
        _from,
        state
      ) do
    reply = transition_entry(state, task_id, expected_revision, event, authority)
    {:reply, reply, state}
  end

  def handle_call({:history, task_id, access}, _from, state) do
    reply =
      with {:ok, entry} <- fetch_entry(state.table, task_id),
           :ok <- authorize_read(access, entry, state, task_id) do
        {:ok, entry.history}
      else
        :not_found -> :not_found
        {:error, {:corrupt_store, _key, _reason}} = error -> error
        _inaccessible -> :not_found
      end

    {:reply, reply, state}
  end

  @impl true
  def terminate(_reason, %{table: table}) do
    _closed = :dets.close(table)
    :ok
  end

  defp open_store(table, path) do
    with :ok <- ensure_parent_directory(path),
         {:ok, ^table} <- open_table(table, path) do
      initialize_open_table(table)
    end
  end

  defp ensure_parent_directory(path) do
    case File.mkdir_p(Path.dirname(path)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:dets_directory_failed, reason}}
    end
  end

  defp open_table(table, path) do
    options = [
      file: String.to_charlist(path),
      type: :set,
      keypos: 1,
      repair: true,
      auto_save: :infinity
    ]

    case :dets.open_file(table, options) do
      {:ok, ^table} = opened -> opened
      {:error, reason} -> {:error, {:dets_open_failed, reason}}
    end
  catch
    kind, reason -> {:error, {:dets_open_failed, {kind, reason}}}
  end

  defp initialize_open_table(table) do
    with {:ok, metadata} <- read_or_initialize_metadata(table),
         :ok <- validate_all_records(table),
         next = %{metadata | boot_epoch: metadata.boot_epoch + 1},
         :ok <- persist_metadata(table, next) do
      {:ok, next}
    else
      {:error, reason} ->
        _closed = :dets.close(table)
        {:error, reason}
    end
  end

  defp read_or_initialize_metadata(table) do
    case lookup_record(table, @metadata_key) do
      {:ok, nil} ->
        if table_size(table) == 0 do
          {:ok, %{store_id: generate_uuid(), boot_epoch: 0}}
        else
          {:error, {:corrupt_store, @metadata_key, :missing_metadata}}
        end

      {:ok, binary} ->
        decode_metadata(binary)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_metadata(binary) do
    with {:ok, encoded} <- decode_json_object(binary),
         %{
           "version" => @metadata_version,
           "storeId" => store_id,
           "bootEpoch" => boot_epoch
         } = exact <- encoded,
         true <- map_size(exact) == 3,
         true <- is_binary(store_id) and Regex.match?(@uuid_pattern, store_id),
         true <- is_integer(boot_epoch) and boot_epoch >= 0 do
      {:ok, %{store_id: store_id, boot_epoch: boot_epoch}}
    else
      %{"version" => version} when version != @metadata_version ->
        {:error, {:unsupported_metadata_version, version}}

      {:error, reason} ->
        {:error, {:corrupt_store, @metadata_key, reason}}

      _invalid ->
        {:error, {:corrupt_store, @metadata_key, :invalid_metadata}}
    end
  end

  defp persist_metadata(table, metadata) do
    encoded = %{
      "version" => @metadata_version,
      "storeId" => metadata.store_id,
      "bootEpoch" => metadata.boot_epoch
    }

    persist_json_record(table, @metadata_key, encoded)
  end

  defp validate_all_records(table) do
    case fold_records(table, :ok, fn
           {@metadata_key, binary}, :ok ->
             validate_metadata_record(binary)

           {{:task, task_id}, binary}, :ok when is_binary(task_id) ->
             validate_task_record(task_id, binary)

           {key, _binary}, :ok ->
             {:error, {:corrupt_store, key, :unknown_record}}

           _record, {:error, _reason} = error ->
             error
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_metadata_record(binary) do
    case decode_metadata(binary) do
      {:ok, _metadata} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_task_record(task_id, binary) do
    case decode_entry(binary, task_id) do
      {:ok, _entry} -> :ok
      {:error, reason} -> {:error, {:corrupt_store, {:task, task_id}, reason}}
    end
  end

  defp create_entry(state, task, work, access) do
    if create_access?(access, state, task.id),
      do: do_create_entry(state, task, work, access, fetch_entry(state.table, task.id)),
      else: {:error, :unauthorized_action}
  end

  defp do_create_entry(_state, _task, _work, _access, {:ok, _entry}),
    do: {:error, :already_exists}

  defp do_create_entry(_state, _task, _work, _access, {:error, reason}),
    do: {:error, reason}

  defp do_create_entry(state, task, work, access, :not_found) do
    snapshot = Snapshot.new(task, work)

    entry = %{
      snapshot: snapshot,
      scope: access.scope,
      claim: nil,
      lease_generation: 0,
      seen_events: %{},
      history: []
    }

    case persist_entry(state.table, task.id, entry) do
      :ok -> {:ok, snapshot}
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, {:invalid_task, exception}}
  end

  defp claim_next_entry(state, owner_id, lease_ms) do
    with {:ok, now} <- read_clock(state.clock),
         {:ok, entries} <- all_entries(state.table) do
      entries
      |> Enum.sort_by(&elem(&1, 0))
      |> claim_first_available(state, owner_id, lease_ms, now)
    end
  end

  defp claim_first_available(entries, state, owner_id, lease_ms, now) do
    Enum.reduce_while(entries, :empty, fn {task_id, entry}, :empty ->
      case claim_entry(entry, state, task_id, owner_id, lease_ms, now) do
        {:ok, claimed, lease} ->
          {:halt, persist_claimed_entry(state.table, task_id, claimed, lease)}

        :unavailable ->
          {:cont, :empty}

        {:deferred, _remaining_ms} ->
          {:cont, :empty}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp persist_claimed_entry(table, task_id, claimed, lease) do
    case persist_entry(table, task_id, claimed) do
      :ok -> {:ok, claimed.snapshot, lease}
      {:error, reason} -> {:error, reason}
    end
  end

  defp renew_claim(state, lease, lease_ms) do
    with {:ok, now} <- read_clock(state.clock),
         {:ok, task_id} <- lease_task_id(lease),
         {:ok, entry} <- fetch_entry(state.table, task_id),
         :ok <- authorize_worker(lease, entry, state, task_id, now),
         {:ok, expires_at} <- add_milliseconds(now, lease_ms),
         renewed = %{lease | expires_at: expires_at},
         next_entry = %{entry | claim: claim_map(renewed)},
         :ok <- persist_entry(state.table, task_id, next_entry) do
      {:ok, renewed}
    else
      {:error, {:corrupt_store, _key, _reason}} = error -> error
      _stale_or_invalid -> {:error, :stale_lease}
    end
  end

  defp release_claim(state, lease) do
    with {:ok, task_id} <- lease_task_id(lease),
         {:ok, entry} <- fetch_entry(state.table, task_id),
         true <- lease_identity_matches?(lease, entry, state, task_id),
         :ok <- persist_entry(state.table, task_id, %{entry | claim: nil}) do
      :ok
    else
      {:error, {:corrupt_store, _key, _reason}} = error -> error
      {:error, reason} -> {:error, reason}
      _stale_or_invalid -> {:error, :stale_lease}
    end
  end

  defp reap_expired(state) do
    with {:ok, now} <- read_clock(state.clock),
         {:ok, entries} <- all_entries(state.table) do
      reaped =
        entries
        |> Enum.filter(fn {_task_id, entry} -> expired_task?(entry.snapshot.task, now) end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      case delete_entries(state.table, reaped) do
        :ok -> {:ok, reaped}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp transition_entry(state, task_id, expected_revision, event, authority) do
    with {:ok, now} <- read_clock(state.clock),
         {:ok, entry} <- fetch_entry(state.table, task_id),
         :ok <- authorize_transition(authority, entry, state, task_id, event.kind, now),
         :ok <- Event.validate(event) do
      apply_or_replay(state, task_id, entry, expected_revision, event, now)
    else
      :not_found -> :not_found
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_or_replay(state, task_id, entry, expected_revision, event, now) do
    case Map.fetch(entry.seen_events, event.id) do
      {:ok, %{event: ^event} = accepted} ->
        duplicate = %Transition{
          outcome: :duplicate,
          snapshot: entry.snapshot,
          effects: accepted.effects,
          event_revision: accepted.event_revision,
          committed_at: accepted.committed_at
        }

        {:ok, duplicate}

      {:ok, _different_event} ->
        {:error, :event_id_reused}

      :error when entry.snapshot.revision != expected_revision ->
        {:conflict, entry.snapshot}

      :error ->
        apply_new_event(state, task_id, entry, event, now)
    end
  end

  defp apply_new_event(state, task_id, entry, event, now) do
    committed_at = monotonic_timestamp(entry.snapshot.task.last_updated_at, now)

    case Transition.apply(entry.snapshot, event, committed_at) do
      {:ok, %Transition{outcome: :unchanged} = transition} ->
        {:ok, transition}

      {:ok, %Transition{outcome: :applied} = transition} ->
        commit_applied_transition(state, task_id, entry, event, transition)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp commit_applied_transition(state, task_id, entry, event, transition) do
    accepted = %{
      event: event,
      committed_at: transition.committed_at,
      event_revision: transition.event_revision,
      effects: transition.effects
    }

    history_entry = %{
      event: event,
      committed_at: transition.committed_at,
      revision: transition.event_revision
    }

    next_entry = %{
      entry
      | snapshot: transition.snapshot,
        seen_events: Map.put(entry.seen_events, event.id, accepted),
        history: entry.history ++ [history_entry]
    }

    case persist_entry(state.table, task_id, next_entry) do
      :ok -> {:ok, transition}
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorize_transition(
         {:request, %Access{} = access},
         entry,
         state,
         task_id,
         event_kind,
         _now
       ) do
    cond do
      not access_store_matches?(access, state) or access.scope != entry.scope ->
        :not_found

      access.action not in [{:update, task_id}, {:cancel, task_id}] ->
        {:error, :unauthorized_action}

      Map.get(@request_events, elem(access.action, 0)) != event_kind ->
        {:error, :unauthorized_action}

      true ->
        :ok
    end
  end

  defp authorize_transition({:worker, lease}, entry, state, task_id, event_kind, now) do
    cond do
      authorize_worker(lease, entry, state, task_id, now) != :ok ->
        {:error, :stale_lease}

      event_kind not in @worker_events ->
        {:error, :unauthorized_action}

      true ->
        :ok
    end
  end

  defp authorize_transition(_authority, _entry, _state, _task_id, _event_kind, _now) do
    {:error, :unauthorized_action}
  end

  defp authorize_worker(%Lease{} = lease, entry, state, task_id, now) do
    if lease_identity_matches?(lease, entry, state, task_id) and
         timestamp_before?(now, lease.expires_at),
       do: :ok,
       else: {:error, :stale_lease}
  end

  defp authorize_worker(_lease, _entry, _state, _task_id, _now),
    do: {:error, :stale_lease}

  defp lease_identity_matches?(%Lease{}, %{claim: nil}, _state, _task_id), do: false

  defp lease_identity_matches?(%Lease{} = lease, %{claim: claim}, state, task_id) do
    lease_store_matches?(lease, state) and lease_claim_matches?(lease, claim, task_id, state)
  end

  defp lease_store_matches?(lease, state) do
    lease.store_id == state.store_id and lease.boot_epoch == state.boot_epoch
  end

  defp lease_claim_matches?(lease, claim, task_id, state) do
    lease.task_id == task_id and lease.token == claim.token and
      lease.generation == claim.generation and lease.owner_id == claim.owner_id and
      lease.expires_at == claim.expires_at and claim.boot_epoch == state.boot_epoch
  end

  defp authorize_read(%Access{} = access, entry, state, task_id) do
    allowed_action? =
      access.action in [{:get, task_id}, {:update, task_id}, {:cancel, task_id}]

    if access_store_matches?(access, state) and access.scope == entry.scope and allowed_action?,
      do: :ok,
      else: :not_found
  end

  defp authorize_read(_access, _entry, _state, _task_id), do: :not_found

  defp create_access?(%Access{} = access, state, task_id) do
    access_store_matches?(access, state) and access.action == {:create, task_id}
  end

  defp create_access?(_access, _state, _task_id), do: false

  defp access_store_matches?(%Access{} = access, state) do
    access.store_id == state.store_id and access.boot_epoch == state.boot_epoch
  end

  defp claim_entry(entry, state, task_id, owner_id, lease_ms, now) do
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

      claim_live?(entry.claim, state.boot_epoch, now) ->
        :unavailable

      true ->
        generation = entry.lease_generation + 1

        with {:ok, expires_at} <- add_milliseconds(now, lease_ms) do
          lease = new_lease(state, task_id, owner_id, generation, expires_at)
          claimed = %{entry | claim: claim_map(lease), lease_generation: generation}
          {:ok, claimed, lease}
        end
    end
  end

  defp claim_live?(nil, _boot_epoch, _now), do: false

  defp claim_live?(claim, boot_epoch, now) do
    claim.boot_epoch == boot_epoch and timestamp_before?(now, claim.expires_at)
  end

  defp new_lease(state, task_id, owner_id, generation, expires_at) do
    %Lease{
      store_id: state.store_id,
      boot_epoch: state.boot_epoch,
      task_id: task_id,
      owner_id: owner_id,
      token: generate_token(),
      generation: generation,
      expires_at: expires_at
    }
  end

  defp claim_map(%Lease{} = lease) do
    %{
      boot_epoch: lease.boot_epoch,
      token: lease.token,
      owner_id: lease.owner_id,
      generation: lease.generation,
      expires_at: lease.expires_at
    }
  end

  defp lease_task_id(%Lease{task_id: task_id}) when is_binary(task_id), do: {:ok, task_id}
  defp lease_task_id(_lease), do: {:error, :stale_lease}

  defp expired_task?(%ProtocolTask{ttl_ms: nil}, _now), do: false

  defp expired_task?(%ProtocolTask{} = task, now) do
    case add_milliseconds(task.created_at, task.ttl_ms) do
      {:ok, expires_at} -> not timestamp_before?(now, expires_at)
      {:error, _invalid_timestamp} -> false
    end
  end

  defp persist_entry(table, task_id, entry) do
    with {:ok, encoded} <- encode_entry(entry) do
      persist_json_record(table, {:task, task_id}, encoded)
    end
  end

  defp encode_entry(entry) do
    encoded = %{
      "version" => @entry_version,
      "snapshot" => Snapshot.to_map(entry.snapshot),
      "scope" => entry.scope,
      "claim" => encode_claim(entry.claim),
      "leaseGeneration" => entry.lease_generation,
      "seenEvents" => encode_seen_events(entry.seen_events),
      "history" => Enum.map(entry.history, &encode_history_entry/1)
    }

    {:ok, encoded}
  rescue
    exception -> {:error, {:entry_encode_failed, exception}}
  end

  defp encode_claim(nil), do: nil

  defp encode_claim(claim) do
    %{
      "bootEpoch" => claim.boot_epoch,
      "token" => claim.token,
      "ownerId" => claim.owner_id,
      "generation" => claim.generation,
      "expiresAt" => claim.expires_at
    }
  end

  defp encode_seen_events(seen_events) do
    Map.new(seen_events, fn {event_id, accepted} ->
      {event_id,
       %{
         "event" => Event.to_map(accepted.event),
         "eventRevision" => accepted.event_revision,
         "committedAt" => accepted.committed_at,
         "effects" => encode_effects(accepted.effects)
       }}
    end)
  end

  defp encode_history_entry(history) do
    %{
      "event" => Event.to_map(history.event),
      "committedAt" => history.committed_at,
      "revision" => history.revision
    }
  end

  defp encode_effects(%{} = effects) when map_size(effects) == 0, do: %{}

  defp encode_effects(%{accepted_input_responses: responses} = effects)
       when map_size(effects) == 1 do
    %{"acceptedInputResponses" => responses}
  end

  defp encode_effects(
         %{
           retry: %{
             disposition: disposition,
             retry_at: retry_at,
             delay_ms: delay_ms,
             retry_count: retry_count
           }
         } = effects
       )
       when map_size(effects) == 1 do
    %{
      "retry" => %{
        "disposition" => Atom.to_string(disposition),
        "retryAt" => retry_at,
        "delayMs" => delay_ms,
        "retryCount" => retry_count
      }
    }
  end

  defp decode_entry(binary, task_id) do
    with {:ok, encoded} <- decode_json_object(binary),
         {:ok, parts} <- decode_entry_parts(encoded),
         true <- parts.snapshot.task.id == task_id,
         :ok <- validate_entry(parts) do
      {:ok, parts}
    else
      false -> {:error, :task_id_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_entry_parts(
         %{
           "version" => @entry_version,
           "snapshot" => encoded_snapshot,
           "scope" => scope,
           "claim" => encoded_claim,
           "leaseGeneration" => lease_generation,
           "seenEvents" => encoded_seen,
           "history" => encoded_history
         } = encoded
       )
       when map_size(encoded) == 7 do
    with {:ok, snapshot} <- Snapshot.from_map(encoded_snapshot),
         {:ok, claim} <- decode_claim(encoded_claim),
         {:ok, seen_events} <- decode_seen_events(encoded_seen),
         {:ok, history} <- decode_history(encoded_history) do
      {:ok,
       %{
         snapshot: snapshot,
         scope: scope,
         claim: claim,
         lease_generation: lease_generation,
         seen_events: seen_events,
         history: history
       }}
    end
  end

  defp decode_entry_parts(%{"version" => version}) when version != @entry_version do
    {:error, {:unsupported_entry_version, version}}
  end

  defp decode_entry_parts(_encoded), do: {:error, :invalid_entry_encoding}

  defp decode_claim(nil), do: {:ok, nil}

  defp decode_claim(
         %{
           "bootEpoch" => boot_epoch,
           "token" => token,
           "ownerId" => owner_id,
           "generation" => generation,
           "expiresAt" => expires_at
         } = encoded
       )
       when map_size(encoded) == 5 do
    claim = %{
      boot_epoch: boot_epoch,
      token: token,
      owner_id: owner_id,
      generation: generation,
      expires_at: expires_at
    }

    case validate_claim(claim) do
      :ok -> {:ok, claim}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_claim(_claim), do: {:error, :invalid_claim_encoding}

  defp decode_seen_events(encoded) when is_map(encoded) do
    Enum.reduce_while(encoded, {:ok, %{}}, fn {event_id, value}, {:ok, seen} ->
      case decode_seen_event(event_id, value) do
        {:ok, accepted} -> {:cont, {:ok, Map.put(seen, event_id, accepted)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp decode_seen_events(_encoded), do: {:error, :invalid_seen_events}

  defp decode_seen_event(
         event_id,
         %{
           "event" => encoded_event,
           "eventRevision" => event_revision,
           "committedAt" => committed_at,
           "effects" => encoded_effects
         } = encoded
       )
       when is_binary(event_id) and map_size(encoded) == 4 do
    with {:ok, event} <- Event.from_map(encoded_event),
         true <- event.id == event_id,
         true <- is_integer(event_revision) and event_revision > 0,
         true <- ProtocolTask.valid_timestamp?(committed_at),
         {:ok, effects} <- decode_effects(encoded_effects) do
      {:ok,
       %{
         event: event,
         event_revision: event_revision,
         committed_at: committed_at,
         effects: effects
       }}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_seen_event}
    end
  end

  defp decode_seen_event(_event_id, _encoded), do: {:error, :invalid_seen_event}

  defp decode_effects(effects) when is_map(effects) and map_size(effects) == 0, do: {:ok, %{}}

  defp decode_effects(%{"acceptedInputResponses" => responses} = effects)
       when map_size(effects) == 1 do
    if is_map(responses) and JSONValue.valid?(responses),
      do: {:ok, %{accepted_input_responses: responses}},
      else: {:error, :invalid_transition_effects}
  end

  defp decode_effects(
         %{
           "retry" =>
             %{
               "disposition" => disposition,
               "retryAt" => retry_at,
               "delayMs" => delay_ms,
               "retryCount" => retry_count
             } = encoded_retry
         } = effects
       )
       when map_size(effects) == 1 and map_size(encoded_retry) == 4 do
    decode_retry_effect(disposition, retry_at, delay_ms, retry_count)
  end

  defp decode_effects(_effects), do: {:error, :invalid_transition_effects}

  defp decode_retry_effect("scheduled", retry_at, delay_ms, retry_count)
       when is_integer(delay_ms) and delay_ms >= 0 and is_integer(retry_count) and
              retry_count > 0 do
    with true <- ProtocolTask.valid_timestamp?(retry_at),
         {:ok, _policy} <- RetryPolicy.new([delay_ms]) do
      {:ok,
       %{
         retry: %{
           disposition: :scheduled,
           retry_at: retry_at,
           delay_ms: delay_ms,
           retry_count: retry_count
         }
       }}
    else
      _invalid -> {:error, :invalid_transition_effects}
    end
  end

  defp decode_retry_effect("exhausted", nil, nil, retry_count)
       when is_integer(retry_count) and retry_count >= 0 do
    {:ok,
     %{
       retry: %{
         disposition: :exhausted,
         retry_at: nil,
         delay_ms: nil,
         retry_count: retry_count
       }
     }}
  end

  defp decode_retry_effect(_disposition, _retry_at, _delay_ms, _retry_count),
    do: {:error, :invalid_transition_effects}

  defp decode_history(encoded) when is_list(encoded) do
    Enum.reduce_while(encoded, {:ok, []}, fn value, {:ok, history} ->
      case decode_history_entry(value) do
        {:ok, entry} -> {:cont, {:ok, [entry | history]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_history(_encoded), do: {:error, :invalid_history}

  defp decode_history_entry(
         %{
           "event" => encoded_event,
           "committedAt" => committed_at,
           "revision" => revision
         } = encoded
       )
       when map_size(encoded) == 3 do
    with {:ok, event} <- Event.from_map(encoded_event),
         true <- is_integer(revision) and revision > 0,
         true <- ProtocolTask.valid_timestamp?(committed_at) do
      {:ok, %{event: event, committed_at: committed_at, revision: revision}}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_history_entry}
    end
  end

  defp decode_history_entry(_encoded), do: {:error, :invalid_history_entry}

  defp validate_entry(entry) do
    with :ok <- Snapshot.validate(entry.snapshot),
         :ok <- validate_scope(entry.scope),
         :ok <- validate_lease_generation(entry.lease_generation),
         :ok <- validate_claim_for_generation(entry.claim, entry.lease_generation) do
      validate_history_ledger(entry)
    end
  end

  defp validate_scope(scope) do
    if JSONValue.valid?(scope), do: :ok, else: {:error, :invalid_persisted_scope}
  end

  defp validate_lease_generation(generation)
       when is_integer(generation) and generation >= 0,
       do: :ok

  defp validate_lease_generation(_generation), do: {:error, :invalid_lease_generation}

  defp validate_claim(claim) do
    valid? =
      Enum.all?([
        positive_integer?(claim.boot_epoch),
        non_empty_string?(claim.token),
        non_empty_string?(claim.owner_id),
        positive_integer?(claim.generation),
        ProtocolTask.valid_timestamp?(claim.expires_at)
      ])

    if valid?, do: :ok, else: {:error, :invalid_claim}
  end

  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp non_empty_string?(value), do: is_binary(value) and value != ""

  defp validate_claim_for_generation(nil, _lease_generation), do: :ok

  defp validate_claim_for_generation(claim, lease_generation) do
    with :ok <- validate_claim(claim),
         true <- claim.generation == lease_generation do
      :ok
    else
      false -> {:error, :claim_generation_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_history_ledger(entry) do
    revisions = Enum.map(entry.history, & &1.revision)
    expected_revisions = revisions_through(entry.snapshot.revision)
    history_ids = Enum.map(entry.history, & &1.event.id) |> MapSet.new()
    seen_ids = Map.keys(entry.seen_events) |> MapSet.new()

    cond do
      revisions != expected_revisions ->
        {:error, :history_revision_mismatch}

      history_ids != seen_ids ->
        {:error, :seen_event_history_mismatch}

      not Enum.all?(entry.history, &history_matches_seen?(&1, entry.seen_events)) ->
        {:error, :seen_event_metadata_mismatch}

      true ->
        validate_history_semantics(entry)
    end
  end

  defp validate_history_semantics(entry) do
    policy = retry_policy(entry.snapshot)

    initial_retry_state = %{
      exhausted?: false,
      latest_failure: nil,
      latest_retry_at: nil,
      scheduled_count: 0
    }

    result =
      Enum.reduce_while(entry.history, {:ok, initial_retry_state}, fn history,
                                                                      {:ok, retry_state} ->
        accepted = Map.fetch!(entry.seen_events, history.event.id)

        case validate_history_effect(
               history,
               accepted.effects,
               policy,
               retry_state,
               entry.snapshot
             ) do
          {:ok, next_retry_state} -> {:cont, {:ok, next_retry_state}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    with {:ok, retry_state} <- result do
      validate_final_retry_state(entry.snapshot, retry_state)
    end
  end

  defp validate_history_effect(
         %{event: %Event{kind: :retry_requested}} = history,
         %{retry: retry},
         policy,
         retry_state,
         snapshot
       ) do
    validate_retry_effect(history, retry, policy, retry_state, snapshot)
  end

  defp validate_history_effect(
         %{event: %Event{kind: :input_responses_accepted, data: %{"responses" => offered}}},
         %{accepted_input_responses: accepted},
         _policy,
         retry_state,
         _snapshot
       ) do
    if map_size(accepted) > 0 and Map.take(offered, Map.keys(accepted)) == accepted,
      do: {:ok, retry_state},
      else: {:error, :event_effect_mismatch}
  end

  defp validate_history_effect(
         %{event: %Event{kind: kind}},
         effects,
         _policy,
         retry_state,
         _snapshot
       )
       when kind in [:input_requested, :completed, :failed, :cancelled] and
              map_size(effects) == 0 do
    {:ok, retry_state}
  end

  defp validate_history_effect(
         _history,
         _effects,
         _policy,
         _retry_state,
         _snapshot
       ),
       do: {:error, :event_effect_mismatch}

  defp validate_retry_effect(
         history,
         %{disposition: :scheduled} = retry,
         policy,
         retry_state,
         _snapshot
       ) do
    expected_count = retry_state.scheduled_count + 1

    cond do
      retry_state.exhausted? or retry.retry_count != expected_count ->
        {:error, :retry_effect_sequence_mismatch}

      RetryPolicy.next_delay(policy, retry_state.scheduled_count) != {:ok, retry.delay_ms} ->
        {:error, :retry_effect_policy_mismatch}

      not retry_timestamp_matches?(history.committed_at, retry.delay_ms, retry.retry_at) ->
        {:error, :retry_effect_timestamp_mismatch}

      true ->
        {:ok,
         %{
           retry_state
           | latest_failure: retry_failure(history.event),
             latest_retry_at: retry.retry_at,
             scheduled_count: expected_count
         }}
    end
  end

  defp validate_retry_effect(
         history,
         %{disposition: :exhausted} = retry,
         policy,
         retry_state,
         snapshot
       ) do
    cond do
      retry_state.exhausted? or retry.retry_count != retry_state.scheduled_count ->
        {:error, :retry_effect_sequence_mismatch}

      RetryPolicy.next_delay(policy, retry_state.scheduled_count) != :exhausted ->
        {:error, :retry_effect_policy_mismatch}

      not exhausted_snapshot_matches?(snapshot, history) ->
        {:error, :retry_exhaustion_snapshot_mismatch}

      true ->
        {:ok,
         %{
           retry_state
           | exhausted?: true,
             latest_failure: retry_failure(history.event),
             latest_retry_at: nil
         }}
    end
  end

  defp validate_retry_effect(
         _history,
         _retry,
         _policy,
         _retry_state,
         _snapshot
       ),
       do: {:error, :event_effect_mismatch}

  defp validate_final_retry_state(snapshot, retry_state) do
    cond do
      retry_state.scheduled_count != snapshot.retry_count ->
        {:error, :retry_snapshot_count_mismatch}

      retry_state.latest_failure != snapshot.last_failure ->
        {:error, :retry_snapshot_failure_mismatch}

      not ProtocolTask.terminal?(snapshot.task) and
          retry_state.latest_retry_at != snapshot.retry_at ->
        {:error, :retry_snapshot_availability_mismatch}

      true ->
        :ok
    end
  end

  defp exhausted_snapshot_matches?(snapshot, history) do
    failure = retry_failure(history.event)

    history.revision == snapshot.revision and snapshot.task.status == :failed and
      snapshot.task.error == failure["error"] and
      snapshot.task.status_message == failure["statusMessage"] and is_nil(snapshot.retry_at)
  end

  defp retry_failure(%Event{data: %{"error" => error, "statusMessage" => status_message}}) do
    %{"error" => error, "statusMessage" => status_message}
  end

  defp retry_policy(%Snapshot{work: %Work{retry_policy: policy}}), do: policy
  defp retry_policy(%Snapshot{}), do: RetryPolicy.none()

  defp retry_timestamp_matches?(committed_at, delay_ms, retry_at) do
    add_milliseconds(committed_at, delay_ms) == {:ok, retry_at}
  end

  defp revisions_through(0), do: []
  defp revisions_through(revision), do: Enum.to_list(1..revision)

  defp history_matches_seen?(history, seen_events) do
    case Map.fetch(seen_events, history.event.id) do
      {:ok, accepted} ->
        accepted.event == history.event and accepted.event_revision == history.revision and
          accepted.committed_at == history.committed_at

      :error ->
        false
    end
  end

  defp fetch_entry(table, task_id) do
    key = {:task, task_id}

    case lookup_record(table, key) do
      {:ok, nil} ->
        :not_found

      {:ok, binary} ->
        case decode_entry(binary, task_id) do
          {:ok, entry} -> {:ok, entry}
          {:error, reason} -> {:error, {:corrupt_store, key, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp all_entries(table) do
    case fold_records(table, {:ok, []}, fn
           {@metadata_key, _binary}, {:ok, entries} ->
             {:ok, entries}

           {{:task, task_id}, binary}, {:ok, entries} when is_binary(task_id) ->
             fold_task_entry(task_id, binary, entries)

           {key, _binary}, {:ok, _entries} ->
             {:error, {:corrupt_store, key, :unknown_record}}

           _record, {:error, _reason} = error ->
             error
         end) do
      {:ok, {:ok, entries}} -> {:ok, entries}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fold_task_entry(task_id, binary, entries) do
    case decode_entry(binary, task_id) do
      {:ok, entry} -> {:ok, [{task_id, entry} | entries]}
      {:error, reason} -> {:error, {:corrupt_store, {:task, task_id}, reason}}
    end
  end

  defp persist_json_record(table, key, encoded) do
    with {:ok, binary} <- encode_json(encoded),
         :ok <- insert_record(table, {key, binary}) do
      sync_table(table)
    end
  end

  defp delete_entries(table, task_ids) do
    with :ok <- delete_task_records(table, task_ids) do
      sync_table(table)
    end
  end

  defp delete_task_records(table, task_ids) do
    Enum.reduce_while(task_ids, :ok, fn task_id, :ok ->
      case delete_record(table, {:task, task_id}) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp encode_json(value) do
    {:ok, JSON.encode!(value)}
  rescue
    exception -> {:error, {:json_encode_failed, exception}}
  end

  defp decode_json_object(binary) when is_binary(binary) do
    case JSON.decode(binary) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      {:ok, _not_an_object} -> {:error, :json_record_not_an_object}
      {:error, reason} -> {:error, {:json_decode_failed, reason}}
    end
  rescue
    exception -> {:error, {:json_decode_failed, exception}}
  end

  defp decode_json_object(_binary), do: {:error, :record_not_binary}

  defp lookup_record(table, key) do
    case :dets.lookup(table, key) do
      [] -> {:ok, nil}
      [{^key, binary}] when is_binary(binary) -> {:ok, binary}
      [_invalid] -> {:error, {:corrupt_store, key, :invalid_record}}
      {:error, reason} -> {:error, {:dets_lookup_failed, reason}}
    end
  catch
    kind, reason -> {:error, {:dets_lookup_failed, {kind, reason}}}
  end

  defp insert_record(table, record) do
    case :dets.insert(table, record) do
      :ok -> :ok
      {:error, reason} -> {:error, {:dets_insert_failed, reason}}
    end
  catch
    kind, reason -> {:error, {:dets_insert_failed, {kind, reason}}}
  end

  defp delete_record(table, key) do
    case :dets.delete(table, key) do
      :ok -> :ok
      {:error, reason} -> {:error, {:dets_delete_failed, reason}}
    end
  catch
    kind, reason -> {:error, {:dets_delete_failed, {kind, reason}}}
  end

  defp sync_table(table) do
    case :dets.sync(table) do
      :ok -> :ok
      {:error, reason} -> {:error, {:dets_sync_failed, reason}}
    end
  catch
    kind, reason -> {:error, {:dets_sync_failed, {kind, reason}}}
  end

  defp fold_records(table, initial, reducer) do
    {:ok, :dets.foldl(reducer, initial, table)}
  catch
    kind, reason -> {:error, {:dets_fold_failed, {kind, reason}}}
  end

  defp table_size(table) do
    case :dets.info(table, :size) do
      size when is_integer(size) -> size
      _unknown -> -1
    end
  end

  defp derive_scope(scope, context) do
    derived = scope.(context)

    if JSONValue.valid?(derived),
      do: {:ok, derived},
      else: {:error, :invalid_scope}
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

  defp generate_token do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp generate_uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    versioned = bor(band(c, 0x0FFF), 0x4000)
    variant = bor(band(d, 0x3FFF), 0x8000)

    Enum.join(
      [hex(a, 8), hex(b, 4), hex(versioned, 4), hex(variant, 4), hex(e, 12)],
      "-"
    )
  end

  defp hex(integer, width) do
    integer
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(width, "0")
  end
end
