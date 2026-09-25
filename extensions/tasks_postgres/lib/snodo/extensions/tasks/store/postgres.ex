defmodule Snodo.Extensions.Tasks.Store.Postgres do
  @moduledoc """
  Multi-node PostgreSQL persistence for the MCP Tasks extension.

  This adapter accepts an application-owned `Ecto.Repo`; it never starts a
  repository or runs migrations. Task snapshots and their serializable work
  descriptors are stored atomically as versioned JSONB. Applied events are
  committed to a separate ledger in the same transaction as the aggregate
  update.

  Claims use PostgreSQL row locks, database time, opaque UUID tokens, exact
  expiry matching, and monotonically increasing generations. Recovery uses
  `FOR UPDATE SKIP LOCKED`, allowing independently supervised runners on
  several nodes to consume the same queue without a coordinator process.

  Recovery remains at least once. Applications must deduplicate external side
  effects with `Snodo.Extensions.Tasks.Work.idempotency_key`.
  """

  @behaviour Snodo.Extensions.Tasks.Store

  import Ecto.Query

  alias Snodo.Context
  alias Snodo.Extensions.Tasks.Event
  alias Snodo.Extensions.Tasks.LedgerValidator
  alias Snodo.Extensions.Tasks.Snapshot
  alias Snodo.Extensions.Tasks.Store.Postgres.Access
  alias Snodo.Extensions.Tasks.Store.Postgres.Config
  alias Snodo.Extensions.Tasks.Store.Postgres.EventRow
  alias Snodo.Extensions.Tasks.Store.Postgres.Lease
  alias Snodo.Extensions.Tasks.Store.Postgres.MetadataRow
  alias Snodo.Extensions.Tasks.Store.Postgres.Migration
  alias Snodo.Extensions.Tasks.Store.Postgres.Persistence
  alias Snodo.Extensions.Tasks.Store.Postgres.TaskRow
  alias Snodo.Extensions.Tasks.Task, as: ProtocolTask
  alias Snodo.Extensions.Tasks.Transition
  alias Snodo.Extensions.Tasks.Work
  alias Snodo.JSONValue

  @default_timeout 15_000
  @default_lock_timeout_ms 5_000
  @default_reap_batch_size 500
  @worker_events [:input_requested, :retry_requested, :completed, :failed]
  @request_events %{update: :input_responses_accepted, cancel: :cancelled}
  @known_options [:repo, :prefix, :scope, :timeout, :lock_timeout_ms, :reap_batch_size]

  @type audit_report :: %{
          checked: non_neg_integer(),
          errors: [map()],
          next_cursor: String.t() | nil
        }

  @doc "Builds immutable adapter configuration around an application-owned Repo."
  @spec new(keyword()) :: {:ok, Config.t()} | {:error, term()}
  def new(opts) when is_list(opts) do
    with :ok <- validate_options(opts),
         {:ok, repo} <- validate_repo(Keyword.get(opts, :repo)),
         {:ok, prefix} <- validate_prefix(Keyword.get(opts, :prefix)),
         {:ok, scope} <- validate_scope_function(Keyword.get(opts, :scope, &default_scope/1)),
         {:ok, timeout} <- positive_option(opts, :timeout, @default_timeout),
         {:ok, lock_timeout_ms} <-
           positive_option(opts, :lock_timeout_ms, @default_lock_timeout_ms),
         {:ok, reap_batch_size} <-
           positive_option(opts, :reap_batch_size, @default_reap_batch_size) do
      {:ok,
       %Config{
         repo: repo,
         prefix: prefix,
         scope: scope,
         timeout: timeout,
         lock_timeout_ms: lock_timeout_ms,
         reap_batch_size: reap_batch_size,
         identity: make_ref()
       }}
    end
  end

  def new(_opts), do: {:error, :invalid_options}

  @doc "Builds adapter configuration or raises `ArgumentError`."
  @spec new!(keyword()) :: Config.t()
  def new!(opts) do
    case new(opts) do
      {:ok, config} -> config
      {:error, reason} -> raise ArgumentError, "invalid PostgreSQL task store: #{inspect(reason)}"
    end
  end

  @doc "Checks that the application has run this adapter's current migration."
  @spec check_schema(Config.t()) :: :ok | {:error, term()}
  def check_schema(%Config{} = config) do
    expected_version = Migration.current_version()

    query =
      from metadata in MetadataRow,
        where: metadata.singleton == true,
        select: metadata.schema_version

    case config.repo.one(query, repo_opts(config)) do
      ^expected_version -> :ok
      nil -> {:error, :schema_metadata_missing}
      version -> {:error, {:unsupported_schema_version, version}}
    end
  rescue
    exception -> {:error, {:database_error, exception}}
  end

  @impl Snodo.Extensions.Tasks.Store
  def authorize(%Config{} = config, %Context{} = context, action) do
    case derive_scope(config.scope, context) do
      {:ok, scope, encoded_scope} ->
        {:ok,
         %Access{
           store_identity: config.identity,
           scope: scope,
           encoded_scope: encoded_scope,
           action: action
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Snodo.Extensions.Tasks.Store
  def create(
        %Config{} = config,
        %ProtocolTask{} = task,
        %Work{} = work,
        access
      ) do
    with :ok <- authorize_create(config, access, task.id),
         snapshot = Snapshot.new(task, work),
         {:ok, projected} <- Persistence.project_snapshot(snapshot),
         {count, nil} <-
           config.repo.insert_all(
             TaskRow,
             [create_attributes(task.id, access.encoded_scope, projected)],
             Keyword.merge(repo_opts(config),
               on_conflict: :nothing,
               conflict_target: [:task_id]
             )
           ) do
      case count do
        1 -> {:ok, snapshot}
        0 -> {:error, :already_exists}
      end
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_database_result, other}}
    end
  rescue
    exception in ArgumentError -> {:error, {:invalid_task, exception}}
  end

  @impl Snodo.Extensions.Tasks.Store
  def get(%Config{} = config, task_id, access) do
    with {:ok, encoded_scope} <- authorize_read(config, access, task_id),
         %TaskRow{} = row <- fetch_scoped_row(config, task_id, encoded_scope),
         {:ok, snapshot} <- decode_task_row(row) do
      {:ok, snapshot}
    else
      nil -> :not_found
      :not_found -> :not_found
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Snodo.Extensions.Tasks.Store
  def worker_snapshot(%Config{} = config, task_id, lease) do
    transact(config, fn -> worker_snapshot_locked(config, task_id, lease) end)
  end

  @impl Snodo.Extensions.Tasks.Store
  def claim(%Config{} = config, task_id, owner_id, lease_ms) do
    transact(config, fn ->
      case fetch_locked_row(config, task_id) do
        nil ->
          :not_found

        %TaskRow{} = row ->
          claim_locked_row(config, row, owner_id, lease_ms)
      end
    end)
  end

  @impl Snodo.Extensions.Tasks.Store
  def claim_next(%Config{} = config, owner_id, lease_ms) do
    transact(config, fn -> claim_next_locked(config, owner_id, lease_ms) end)
  end

  @impl Snodo.Extensions.Tasks.Store
  def renew(%Config{} = config, lease, lease_ms) do
    transact(config, fn -> renew_locked_claim(config, lease, lease_ms) end)
  end

  @impl Snodo.Extensions.Tasks.Store
  def release(%Config{} = config, lease) do
    transact(config, fn -> release_locked_claim(config, lease) end)
  end

  @impl Snodo.Extensions.Tasks.Store
  def reap(%Config{} = config) do
    transact(config, fn -> reap_locked_batch(config) end)
  end

  @impl Snodo.Extensions.Tasks.Store
  def transition(
        %Config{} = config,
        task_id,
        expected_revision,
        %Event{} = event,
        authority
      ) do
    case prepare_authority(config, authority, task_id, event.kind) do
      {:ok, prepared_authority} ->
        transact(config, fn ->
          transition_locked(config, task_id, expected_revision, event, prepared_authority)
        end)

      :not_found ->
        :not_found

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Returns applied event history through the same scoped read authority as `get/3`."
  @spec history(Config.t(), String.t(), term()) ::
          {:ok, [map()]} | :not_found | {:error, term()}
  def history(%Config{} = config, task_id, access) do
    case authorize_read(config, access, task_id) do
      {:ok, encoded_scope} ->
        transact(config, fn -> history_locked(config, task_id, encoded_scope) end)

      :not_found ->
        :not_found
    end
  end

  @doc "Audits a bounded page of aggregates and event ledgers without mutating them."
  @spec audit(Config.t(), keyword()) :: {:ok, audit_report()} | {:error, term()}
  def audit(config, opts \\ [])

  def audit(%Config{} = config, opts) when is_list(opts) do
    with {:ok, limit} <- audit_limit(opts),
         {:ok, cursor} <- audit_cursor(opts) do
      audit_page(config, cursor, limit)
    end
  rescue
    exception -> {:error, {:database_error, exception}}
  end

  def audit(%Config{}, _opts), do: {:error, :invalid_audit_options}

  @doc false
  @spec project_snapshot(Snapshot.t()) :: {:ok, map()} | {:error, term()}
  defdelegate project_snapshot(snapshot), to: Persistence

  defp validate_options(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- @known_options == [],
      do: :ok,
      else: {:error, :invalid_options}
  end

  defp validate_repo(repo) when is_atom(repo) and not is_nil(repo) do
    with {:module, ^repo} <- Code.ensure_loaded(repo),
         true <- function_exported?(repo, :__adapter__, 0),
         Ecto.Adapters.Postgres <- repo.__adapter__() do
      {:ok, repo}
    else
      _invalid -> {:error, :repo_must_use_ecto_postgres}
    end
  rescue
    _exception -> {:error, :repo_must_use_ecto_postgres}
  end

  defp validate_repo(_repo), do: {:error, :repo_must_use_ecto_postgres}

  defp validate_prefix(nil), do: {:ok, nil}
  defp validate_prefix(prefix) when is_binary(prefix) and prefix != "", do: {:ok, prefix}
  defp validate_prefix(_prefix), do: {:error, :invalid_prefix}

  defp validate_scope_function(scope) when is_function(scope, 1), do: {:ok, scope}
  defp validate_scope_function(_scope), do: {:error, :invalid_scope_function}

  defp positive_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _invalid -> {:error, {:invalid_positive_option, key}}
    end
  end

  defp default_scope(_context), do: "shared"

  defp derive_scope(scope_function, context) do
    scope = scope_function.(context)

    with true <- JSONValue.valid?(scope),
         {:ok, encoded} <- Jason.encode(scope),
         {:ok, normalized} <- Jason.decode(encoded) do
      {:ok, normalized, scope_record(normalized)}
    else
      _invalid -> {:error, :invalid_scope}
    end
  rescue
    exception -> {:error, {:scope_exception, exception, __STACKTRACE__}}
  catch
    kind, reason -> {:error, {:scope_exit, kind, reason, __STACKTRACE__}}
  end

  defp scope_record(scope), do: %{"version" => 1, "value" => scope}

  defp authorize_create(%Config{} = config, %Access{} = access, task_id) do
    if access.store_identity == config.identity and access.action == {:create, task_id},
      do: :ok,
      else: {:error, :unauthorized_action}
  end

  defp authorize_create(_config, _access, _task_id), do: {:error, :unauthorized_action}

  defp authorize_read(%Config{} = config, %Access{} = access, task_id) do
    allowed_action? = access.action in [{:get, task_id}, {:update, task_id}, {:cancel, task_id}]

    if access.store_identity == config.identity and allowed_action?,
      do: {:ok, access.encoded_scope},
      else: :not_found
  end

  defp authorize_read(_config, _access, _task_id), do: :not_found

  defp create_attributes(task_id, encoded_scope, projected) do
    projected
    |> Map.take([
      :row_format,
      :snapshot_format,
      :snapshot,
      :revision,
      :status,
      :created_at,
      :expires_at,
      :retry_at
    ])
    |> Map.merge(%{
      task_id: task_id,
      authorization_scope: encoded_scope,
      lease_generation: 0
    })
  end

  defp fetch_scoped_row(config, task_id, encoded_scope) do
    query =
      from task in TaskRow,
        where: task.task_id == ^task_id,
        where: task.authorization_scope == ^encoded_scope

    config.repo.one(query, repo_opts(config))
  end

  defp fetch_locked_row(config, task_id, encoded_scope \\ :unscoped) do
    query =
      from task in TaskRow,
        where: task.task_id == ^task_id,
        lock: "FOR UPDATE"

    scoped_query =
      case encoded_scope do
        :unscoped -> query
        scope -> where(query, [task], task.authorization_scope == ^scope)
      end

    config.repo.one(scoped_query, repo_opts(config))
  end

  defp fetch_shared_row(config, task_id, encoded_scope) do
    query =
      from task in TaskRow,
        where: task.task_id == ^task_id,
        where: task.authorization_scope == ^encoded_scope,
        lock: "FOR SHARE"

    config.repo.one(query, repo_opts(config))
  end

  defp decode_task_row(%TaskRow{} = row) do
    case Persistence.decode_task_row(row) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, reason} -> {:error, {:corrupt_store, row.task_id, reason}}
    end
  end

  defp worker_snapshot_locked(config, task_id, lease) do
    case fetch_locked_row(config, task_id) do
      nil ->
        :not_found

      %TaskRow{} = row ->
        with {:ok, snapshot} <- decode_task_row(row),
             {:ok, now} <- database_now(config),
             :ok <- authorize_worker(config, lease, row, task_id, now) do
          {:ok, snapshot}
        end
    end
  end

  defp claim_next_locked(config, owner_id, lease_ms) do
    query =
      from task in TaskRow,
        where: task.status in ["working", "input_required"],
        where: is_nil(task.retry_at) or task.retry_at <= fragment("statement_timestamp()"),
        where:
          is_nil(task.claim_expires_at) or
            task.claim_expires_at <= fragment("statement_timestamp()"),
        order_by: [asc: task.created_at, asc: task.task_id],
        limit: 1,
        lock: "FOR UPDATE SKIP LOCKED"

    config.repo.one(query, repo_opts(config))
    |> claim_next_result(config, owner_id, lease_ms)
  end

  defp claim_next_result(nil, _config, _owner_id, _lease_ms), do: :empty

  defp claim_next_result(%TaskRow{} = row, config, owner_id, lease_ms) do
    case claim_locked_row(config, row, owner_id, lease_ms) do
      :unavailable -> :empty
      {:deferred, _remaining_ms} -> :empty
      claimed -> claimed
    end
  end

  defp claim_locked_row(config, %TaskRow{} = row, owner_id, lease_ms) do
    with {:ok, snapshot} <- decode_task_row(row),
         {:ok, now} <- database_now(config) do
      retry_availability =
        Snapshot.retry_availability(snapshot, DateTime.to_iso8601(now))

      cond do
        ProtocolTask.terminal?(snapshot.task) ->
          :unavailable

        is_nil(snapshot.work) ->
          :unavailable

        match?({:deferred, _remaining_ms}, retry_availability) ->
          retry_availability

        retry_availability == :invalid ->
          {:error, :invalid_retry_availability}

        claim_live?(row, now) ->
          :unavailable

        true ->
          persist_new_claim(config, row, snapshot, owner_id, lease_ms, now)
      end
    end
  end

  defp persist_new_claim(config, row, snapshot, owner_id, lease_ms, now) do
    token = Ecto.UUID.generate()
    generation = row.lease_generation + 1
    expires_at = DateTime.add(now, lease_ms, :millisecond)

    query = from task in TaskRow, where: task.task_id == ^row.task_id

    {count, nil} =
      config.repo.update_all(
        query,
        [
          set: [
            claim_owner: owner_id,
            claim_token: token,
            lease_generation: generation,
            claim_expires_at: expires_at,
            updated_at: now
          ]
        ],
        repo_opts(config)
      )

    ensure_one!(count, :claim_update_lost)

    lease = %Lease{
      store_identity: config.identity,
      task_id: row.task_id,
      owner_id: owner_id,
      token: token,
      generation: generation,
      expires_at: expires_at
    }

    {:ok, snapshot, lease}
  end

  defp renew_locked_claim(config, %Lease{task_id: task_id} = lease, lease_ms) do
    case fetch_locked_row(config, task_id) do
      nil ->
        {:error, :stale_lease}

      %TaskRow{} = row ->
        with {:ok, _snapshot} <- decode_task_row(row),
             {:ok, now} <- database_now(config),
             :ok <- authorize_worker(config, lease, row, task_id, now) do
          expires_at = DateTime.add(now, lease_ms, :millisecond)
          query = from task in TaskRow, where: task.task_id == ^task_id

          {count, nil} =
            config.repo.update_all(
              query,
              [set: [claim_expires_at: expires_at, updated_at: now]],
              repo_opts(config)
            )

          ensure_one!(count, :renew_update_lost)
          {:ok, %{lease | expires_at: expires_at}}
        else
          {:error, {:corrupt_store, _task_id, _reason}} = error -> error
          _stale -> {:error, :stale_lease}
        end
    end
  end

  defp renew_locked_claim(_config, _lease, _lease_ms), do: {:error, :stale_lease}

  defp release_locked_claim(config, %Lease{task_id: task_id} = lease) do
    case fetch_locked_row(config, task_id) do
      nil ->
        {:error, :stale_lease}

      %TaskRow{} = row ->
        with {:ok, _snapshot} <- decode_task_row(row),
             true <- lease_identity_matches?(config, lease, row, task_id) do
          query = from task in TaskRow, where: task.task_id == ^task_id

          {count, nil} =
            config.repo.update_all(
              query,
              [set: [claim_owner: nil, claim_token: nil, claim_expires_at: nil]],
              repo_opts(config)
            )

          ensure_one!(count, :release_update_lost)
          :ok
        else
          {:error, {:corrupt_store, _task_id, _reason}} = error -> error
          _stale -> {:error, :stale_lease}
        end
    end
  end

  defp release_locked_claim(_config, _lease), do: {:error, :stale_lease}

  defp reap_locked_batch(config) do
    query =
      from task in TaskRow,
        where: not is_nil(task.expires_at),
        where: task.expires_at <= fragment("statement_timestamp()"),
        order_by: [asc: task.expires_at, asc: task.task_id],
        limit: ^config.reap_batch_size,
        lock: "FOR UPDATE SKIP LOCKED"

    rows = config.repo.all(query, repo_opts(config))

    with :ok <- validate_reap_rows(rows) do
      task_ids = Enum.map(rows, & &1.task_id)

      if task_ids != [] do
        delete_query = from task in TaskRow, where: task.task_id in ^task_ids
        {count, nil} = config.repo.delete_all(delete_query, repo_opts(config))
        ensure_count!(count, length(task_ids), :reap_delete_lost)
      end

      {:ok, task_ids}
    end
  end

  defp validate_reap_rows(rows) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      case decode_task_row(row) do
        {:ok, _snapshot} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp prepare_authority(
         config,
         {:request, %Access{} = access},
         task_id,
         event_kind
       ) do
    cond do
      access.store_identity != config.identity ->
        :not_found

      access.action not in [{:update, task_id}, {:cancel, task_id}] ->
        {:error, :unauthorized_action}

      Map.get(@request_events, elem(access.action, 0)) != event_kind ->
        {:error, :unauthorized_action}

      true ->
        {:ok, {:request, access}}
    end
  end

  defp prepare_authority(config, {:worker, %Lease{} = lease}, task_id, event_kind) do
    cond do
      lease.store_identity != config.identity -> {:error, :stale_lease}
      lease.task_id != task_id -> {:error, :stale_lease}
      event_kind not in @worker_events -> {:error, :unauthorized_action}
      true -> {:ok, {:worker, lease}}
    end
  end

  defp prepare_authority(_config, _authority, _task_id, _event_kind),
    do: {:error, :unauthorized_action}

  defp transition_locked(config, task_id, expected_revision, event, authority) do
    encoded_scope =
      case authority do
        {:request, %Access{encoded_scope: scope}} -> scope
        {:worker, _lease} -> :unscoped
      end

    case fetch_locked_row(config, task_id, encoded_scope) do
      nil ->
        :not_found

      %TaskRow{} = row ->
        with {:ok, snapshot} <- decode_task_row(row),
             {:ok, now} <- database_now(config),
             :ok <- authorize_locked_transition(config, authority, row, task_id, now),
             :ok <- Event.validate(event) do
          apply_or_replay(config, row, snapshot, expected_revision, event, now)
        end
    end
  end

  defp authorize_locked_transition(_config, {:request, %Access{}}, _row, _task_id, _now),
    do: :ok

  defp authorize_locked_transition(config, {:worker, lease}, row, task_id, now),
    do: authorize_worker(config, lease, row, task_id, now)

  defp apply_or_replay(config, row, snapshot, expected_revision, event, now) do
    case fetch_event_row(config, row.task_id, event.id) do
      %EventRow{} = event_row ->
        replay_event(config, event_row, event, snapshot, row.task_id)

      nil when snapshot.revision != expected_revision ->
        {:conflict, snapshot}

      nil ->
        apply_new_event(config, row, snapshot, event, now)
    end
  end

  defp replay_event(config, event_row, event, snapshot, task_id) do
    with {:ok, accepted} <- Persistence.decode_event_row(event_row),
         :ok <- validate_event_task_id(accepted, task_id),
         {:ok, records} <- load_history(config, task_id),
         :ok <- validate_ledger(snapshot, records, task_id) do
      case accepted do
        %{event: ^event} ->
          {:ok,
           %Transition{
             outcome: :duplicate,
             snapshot: snapshot,
             effects: accepted.effects,
             event_revision: accepted.revision,
             committed_at: accepted.committed_at
           }}

        _different_event ->
          {:error, :event_id_reused}
      end
    else
      {:error, {:corrupt_store, ^task_id, _reason} = corrupt_store} ->
        {:error, corrupt_store}

      {:error, reason} ->
        {:error, {:corrupt_store, task_id, reason}}
    end
  end

  defp apply_new_event(config, row, snapshot, event, now) do
    with {:ok, committed_at} <- monotonic_timestamp(snapshot.task.last_updated_at, now),
         {:ok, transition} <- Transition.apply(snapshot, event, committed_at) do
      case transition.outcome do
        :unchanged -> {:ok, transition}
        :applied -> commit_transition(config, row, event, transition)
      end
    end
  end

  defp commit_transition(config, row, event, transition) do
    with {:ok, projected} <- Persistence.project_snapshot(transition.snapshot),
         {:ok, effects} <- Persistence.encode_effects(transition.effects),
         {:ok, committed_at} <- parse_timestamp(transition.committed_at) do
      update_query =
        from task in TaskRow,
          where: task.task_id == ^row.task_id,
          where: task.revision == ^row.revision

      {count, nil} =
        config.repo.update_all(
          update_query,
          [
            set: [
              row_format: projected.row_format,
              snapshot_format: projected.snapshot_format,
              snapshot: projected.snapshot,
              revision: projected.revision,
              status: projected.status,
              created_at: projected.created_at,
              expires_at: projected.expires_at,
              retry_at: projected.retry_at,
              updated_at: committed_at
            ]
          ],
          repo_opts(config)
        )

      ensure_one!(count, :transition_update_lost)

      {event_count, nil} =
        config.repo.insert_all(
          EventRow,
          [
            %{
              task_id: row.task_id,
              event_id: event.id,
              row_format: Persistence.row_format(),
              event: Event.to_map(event),
              event_kind: Atom.to_string(event.kind),
              event_revision: transition.event_revision,
              committed_at: committed_at,
              effects: effects
            }
          ],
          repo_opts(config)
        )

      ensure_one!(event_count, :event_insert_lost)
      {:ok, transition}
    end
  end

  defp fetch_event_row(config, task_id, event_id) do
    query =
      from event in EventRow,
        where: event.task_id == ^task_id,
        where: event.event_id == ^event_id

    config.repo.one(query, repo_opts(config))
  end

  defp load_history(config, task_id) do
    query =
      from event in EventRow,
        where: event.task_id == ^task_id,
        order_by: [asc: event.event_revision]

    config.repo.all(query, repo_opts(config))
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, records} ->
      case Persistence.decode_event_row(row) do
        {:ok, record} -> {:cont, {:ok, [record | records]}}
        {:error, reason} -> {:halt, {:error, {:corrupt_store, task_id, reason}}}
      end
    end)
    |> then(fn
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end)
  end

  defp history_locked(config, task_id, encoded_scope) do
    case fetch_shared_row(config, task_id, encoded_scope) do
      nil ->
        :not_found

      %TaskRow{} = row ->
        with {:ok, snapshot} <- decode_task_row(row),
             {:ok, records} <- load_history(config, task_id),
             :ok <- validate_ledger(snapshot, records, task_id) do
          {:ok,
           Enum.map(records, fn record ->
             %{
               event: record.event,
               committed_at: record.committed_at,
               revision: record.revision
             }
           end)}
        end
    end
  end

  defp validate_ledger(%Snapshot{} = snapshot, records, task_id) do
    case LedgerValidator.validate(snapshot, records, task_id) do
      :ok -> :ok
      {:error, reason} -> {:error, {:corrupt_store, task_id, reason}}
    end
  end

  defp validate_event_task_id(%{task_id: task_id}, task_id), do: :ok
  defp validate_event_task_id(_record, _task_id), do: {:error, :event_task_id_projection_mismatch}

  defp authorize_worker(config, %Lease{} = lease, row, task_id, now) do
    if lease_identity_matches?(config, lease, row, task_id) and
         DateTime.compare(now, lease.expires_at) == :lt,
       do: :ok,
       else: {:error, :stale_lease}
  end

  defp authorize_worker(_config, _lease, _row, _task_id, _now),
    do: {:error, :stale_lease}

  defp lease_identity_matches?(config, %Lease{} = lease, %TaskRow{} = row, task_id) do
    lease.store_identity == config.identity and lease.task_id == task_id and
      lease.owner_id == row.claim_owner and lease.token == row.claim_token and
      lease.generation == row.lease_generation and
      datetime_same?(lease.expires_at, row.claim_expires_at)
  end

  defp claim_live?(%TaskRow{claim_expires_at: nil}, _now), do: false

  defp claim_live?(%TaskRow{claim_expires_at: expires_at}, now) do
    DateTime.compare(now, expires_at) == :lt
  end

  defp database_now(config) do
    case Ecto.Adapters.SQL.query(
           config.repo,
           "SELECT clock_timestamp()",
           [],
           timeout: config.timeout
         ) do
      {:ok, %{rows: [[%DateTime{} = now]]}} -> {:ok, now}
      {:ok, other} -> {:error, {:invalid_database_clock_result, other}}
      {:error, reason} -> {:error, {:database_clock_failed, reason}}
    end
  end

  defp monotonic_timestamp(last_updated_at, now) do
    with {:ok, last_updated} <- parse_timestamp(last_updated_at) do
      committed_at =
        if DateTime.compare(now, last_updated) == :gt,
          do: now,
          else: DateTime.add(last_updated, 1, :microsecond)

      {:ok, DateTime.to_iso8601(committed_at)}
    end
  rescue
    ArgumentError -> {:error, :invalid_commit_timestamp}
  end

  defp parse_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> {:error, :invalid_timestamp}
    end
  end

  defp datetime_same?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) == :eq

  defp datetime_same?(_left, _right), do: false

  defp transact(config, function) do
    case config.repo.transact(
           fn ->
             set_local_lock_timeout(config)
             transaction_result(function.())
           end,
           timeout: config.timeout
         ) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp transaction_result({:error, reason}), do: {:error, reason}
  defp transaction_result(result), do: {:ok, result}

  defp set_local_lock_timeout(config) do
    timeout = Integer.to_string(config.lock_timeout_ms) <> "ms"

    case Ecto.Adapters.SQL.query(
           config.repo,
           "SELECT set_config('lock_timeout', $1, true)",
           [timeout],
           timeout: config.timeout
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> raise "could not set PostgreSQL lock timeout: #{inspect(reason)}"
    end
  end

  defp repo_opts(%Config{prefix: nil, timeout: timeout}), do: [timeout: timeout]

  defp repo_opts(%Config{prefix: prefix, timeout: timeout}),
    do: [prefix: prefix, timeout: timeout]

  defp ensure_one!(1, _reason), do: :ok
  defp ensure_one!(_count, reason), do: raise("task store invariant failed: #{reason}")

  defp ensure_count!(count, count, _reason), do: :ok

  defp ensure_count!(_actual, _expected, reason),
    do: raise("task store invariant failed: #{reason}")

  defp audit_limit(opts) do
    case Keyword.get(opts, :limit, 100) do
      limit when is_integer(limit) and limit > 0 and limit <= 10_000 -> {:ok, limit}
      _invalid -> {:error, :invalid_audit_limit}
    end
  end

  defp audit_cursor(opts) do
    case Keyword.get(opts, :after) do
      nil -> {:ok, nil}
      cursor when is_binary(cursor) and cursor != "" -> {:ok, cursor}
      _invalid -> {:error, :invalid_audit_cursor}
    end
  end

  defp audit_page(config, cursor, limit) do
    base_query =
      from task in TaskRow,
        order_by: [asc: task.task_id],
        limit: ^limit

    query =
      if is_nil(cursor), do: base_query, else: where(base_query, [task], task.task_id > ^cursor)

    rows = config.repo.all(query, repo_opts(config))
    errors = Enum.flat_map(rows, &audit_errors(config, &1))
    next_cursor = if length(rows) == limit, do: List.last(rows).task_id, else: nil

    {:ok, %{checked: length(rows), errors: errors, next_cursor: next_cursor}}
  end

  defp audit_errors(config, row) do
    case audit_one(config, row.task_id) do
      :ok -> []
      {:error, reason} -> [%{task_id: row.task_id, reason: reason}]
    end
  end

  defp audit_one(config, task_id) do
    transact(config, fn ->
      query =
        from task in TaskRow,
          where: task.task_id == ^task_id,
          lock: "FOR SHARE"

      case config.repo.one(query, repo_opts(config)) do
        nil -> :ok
        %TaskRow{} = row -> audit_locked_row(config, row)
      end
    end)
  end

  defp audit_locked_row(config, row) do
    with {:ok, snapshot} <- decode_task_row(row),
         {:ok, records} <- load_history(config, row.task_id) do
      validate_ledger(snapshot, records, row.task_id)
    end
  end
end
