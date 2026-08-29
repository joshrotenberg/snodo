defmodule MCP.Extensions.Tasks.Store.SQLite do
  @moduledoc """
  Single-host SQLite persistence for the MCP Tasks extension.

  This adapter accepts an application-owned `Ecto.Repo`; it never starts a
  repository, creates a database file, or runs migrations. Task snapshots and
  serializable work descriptors are stored atomically as versioned JSON. Each
  applied event is committed to a separate ledger in the same transaction as
  the aggregate update.

  SQLite has no row locks and permits only one writer. Every store mutation
  therefore uses an `IMMEDIATE` transaction, acquiring the database write
  reservation before it reads availability, lease, revision, or clock state.
  Competing writers wait according to the application Repo's `:busy_timeout`.
  Exhausted contention is normalized to `{:error, :database_busy}`.

  The supported deployment boundary is a file-backed WAL database on one
  host. Recovery remains at least once, so applications must deduplicate
  external effects with `MCP.Extensions.Tasks.Work.idempotency_key`.
  """

  @behaviour MCP.Extensions.Tasks.Store

  import Ecto.Query

  alias MCP.Context
  alias MCP.Extensions.Tasks.Event
  alias MCP.Extensions.Tasks.LedgerValidator
  alias MCP.Extensions.Tasks.Snapshot
  alias MCP.Extensions.Tasks.Store.SQLite.Access
  alias MCP.Extensions.Tasks.Store.SQLite.Config
  alias MCP.Extensions.Tasks.Store.SQLite.EventRow
  alias MCP.Extensions.Tasks.Store.SQLite.Lease
  alias MCP.Extensions.Tasks.Store.SQLite.MetadataRow
  alias MCP.Extensions.Tasks.Store.SQLite.Migration
  alias MCP.Extensions.Tasks.Store.SQLite.Persistence
  alias MCP.Extensions.Tasks.Store.SQLite.TaskRow
  alias MCP.Extensions.Tasks.Store.SQLite.Timestamp
  alias MCP.Extensions.Tasks.Task, as: ProtocolTask
  alias MCP.Extensions.Tasks.Transition
  alias MCP.Extensions.Tasks.Work
  alias MCP.JSONValue

  @default_timeout 15_000
  @default_reap_batch_size 500
  @worker_events [:input_requested, :retry_requested, :completed, :failed]
  @request_events %{update: :input_responses_accepted, cancel: :cancelled}
  @known_options [:repo, :scope, :timeout, :reap_batch_size]

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
         {:ok, scope} <- validate_scope_function(Keyword.get(opts, :scope, &default_scope/1)),
         {:ok, timeout} <- positive_option(opts, :timeout, @default_timeout),
         {:ok, reap_batch_size} <-
           positive_option(opts, :reap_batch_size, @default_reap_batch_size) do
      {:ok,
       %Config{
         repo: repo,
         scope: scope,
         timeout: timeout,
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
      {:error, reason} -> raise ArgumentError, "invalid SQLite task store: #{inspect(reason)}"
    end
  end

  @doc "Checks the migration and required file-backed WAL Repo settings."
  @spec check_schema(Config.t()) :: :ok | {:error, term()}
  def check_schema(%Config{} = config) do
    database_call(fn ->
      config.repo.checkout(
        fn -> check_schema_checked_out(config) end,
        timeout: config.timeout
      )
    end)
  end

  @impl MCP.Extensions.Tasks.Store
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

  @impl MCP.Extensions.Tasks.Store
  def create(%Config{} = config, %ProtocolTask{} = task, %Work{} = work, access) do
    with :ok <- authorize_create(config, access, task.id),
         snapshot = Snapshot.new(task, work),
         {:ok, projected} <- Persistence.project_snapshot(snapshot),
         {:ok, encoded_scope} <- Persistence.encode_json(access.encoded_scope) do
      transact_write(config, fn ->
        insert_new_snapshot(config, task.id, encoded_scope, projected, snapshot)
      end)
    end
  rescue
    exception in ArgumentError -> {:error, {:invalid_task, exception}}
  end

  @impl MCP.Extensions.Tasks.Store
  def get(%Config{} = config, task_id, access) do
    with {:ok, encoded_scope} <- authorize_read(config, access, task_id),
         %TaskRow{} = row <- fetch_row(config, task_id),
         true <- scope_matches?(row, encoded_scope),
         {:ok, snapshot} <- decode_task_row(row) do
      {:ok, snapshot}
    else
      nil -> :not_found
      false -> :not_found
      :not_found -> :not_found
      {:error, reason} -> {:error, reason}
    end
  end

  @impl MCP.Extensions.Tasks.Store
  def worker_snapshot(%Config{} = config, task_id, lease) do
    transact_read(config, fn -> worker_snapshot_consistent(config, task_id, lease) end)
  end

  @impl MCP.Extensions.Tasks.Store
  def claim(%Config{} = config, task_id, owner_id, lease_ms) do
    transact_write(config, fn -> claim_exact_serialized(config, task_id, owner_id, lease_ms) end)
  end

  @impl MCP.Extensions.Tasks.Store
  def claim_next(%Config{} = config, owner_id, lease_ms) do
    transact_write(config, fn -> claim_next_serialized(config, owner_id, lease_ms) end)
  end

  @impl MCP.Extensions.Tasks.Store
  def renew(%Config{} = config, lease, lease_ms) do
    transact_write(config, fn -> renew_serialized_claim(config, lease, lease_ms) end)
  end

  @impl MCP.Extensions.Tasks.Store
  def release(%Config{} = config, lease) do
    transact_write(config, fn -> release_serialized_claim(config, lease) end)
  end

  @impl MCP.Extensions.Tasks.Store
  def reap(%Config{} = config) do
    transact_write(config, fn -> reap_serialized_batch(config) end)
  end

  @impl MCP.Extensions.Tasks.Store
  def transition(
        %Config{} = config,
        task_id,
        expected_revision,
        %Event{} = event,
        authority
      ) do
    case prepare_authority(config, authority, task_id, event.kind) do
      {:ok, prepared_authority} ->
        transact_write(config, fn ->
          transition_serialized(config, task_id, expected_revision, event, prepared_authority)
        end)

      other ->
        other
    end
  end

  @doc "Returns the validated applied-event history visible to request access."
  @spec history(Config.t(), String.t(), term()) ::
          {:ok, [map()]} | :not_found | {:error, term()}
  def history(%Config{} = config, task_id, access) do
    with {:ok, encoded_scope} <- authorize_read(config, access, task_id) do
      transact_read(config, fn -> history_consistent(config, task_id, encoded_scope) end)
    end
  end

  @doc "Audits one bounded page of aggregate and ledger rows."
  @spec audit(Config.t(), keyword()) :: {:ok, audit_report()} | {:error, term()}
  def audit(config, opts \\ [])

  def audit(%Config{} = config, opts) when is_list(opts) do
    with {:ok, limit} <- audit_limit(opts),
         {:ok, cursor} <- audit_cursor(opts) do
      audit_page(config, cursor, limit)
    end
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
         Ecto.Adapters.SQLite3 <- repo.__adapter__() do
      {:ok, repo}
    else
      _invalid -> {:error, :repo_must_use_ecto_sqlite3}
    end
  rescue
    _exception -> {:error, :repo_must_use_ecto_sqlite3}
  end

  defp validate_repo(_repo), do: {:error, :repo_must_use_ecto_sqlite3}

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
      :created_at_us,
      :expires_at_us,
      :retry_at_us
    ])
    |> Map.merge(%{
      task_id: task_id,
      authorization_scope: encoded_scope,
      lease_generation: 0
    })
  end

  defp insert_new_snapshot(config, task_id, encoded_scope, projected, snapshot) do
    result =
      config.repo.insert_all(
        TaskRow,
        [create_attributes(task_id, encoded_scope, projected)],
        Keyword.merge(repo_opts(config),
          on_conflict: :nothing,
          conflict_target: [:task_id]
        )
      )

    case result do
      {1, nil} -> {:ok, snapshot}
      {0, nil} -> {:error, :already_exists}
      other -> {:error, {:unexpected_database_result, other}}
    end
  end

  defp fetch_row(config, task_id) do
    query = from task in TaskRow, where: task.task_id == ^task_id
    database_call(fn -> config.repo.one(query, repo_opts(config)) end)
  end

  defp fetch_row_in_transaction(config, task_id) do
    query = from task in TaskRow, where: task.task_id == ^task_id
    config.repo.one(query, repo_opts(config))
  end

  defp scope_matches?(%TaskRow{} = row, encoded_scope),
    do: Persistence.authorization_scope_matches?(row.authorization_scope, encoded_scope)

  defp decode_task_row(%TaskRow{} = row) do
    case Persistence.decode_task_row(row) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, reason} -> {:error, {:corrupt_store, row.task_id, reason}}
    end
  end

  defp worker_snapshot_consistent(config, task_id, lease) do
    case fetch_row_in_transaction(config, task_id) do
      nil ->
        :not_found

      %TaskRow{} = row ->
        with {:ok, snapshot} <- decode_task_row(row),
             {:ok, now_us} <- database_now_us(config),
             :ok <- authorize_worker(config, lease, row, task_id, now_us) do
          {:ok, snapshot}
        end
    end
  end

  defp claim_exact_serialized(config, task_id, owner_id, lease_ms) do
    with {:ok, now_us} <- database_now_us(config) do
      case fetch_row_in_transaction(config, task_id) do
        nil -> :not_found
        %TaskRow{} = row -> claim_serialized_row(config, row, owner_id, lease_ms, now_us)
      end
    end
  end

  defp claim_next_serialized(config, owner_id, lease_ms) do
    with {:ok, now_us} <- database_now_us(config) do
      query =
        from task in TaskRow,
          where: task.status in ["working", "input_required"],
          where: is_nil(task.retry_at_us) or task.retry_at_us <= ^now_us,
          where: is_nil(task.claim_expires_at_us) or task.claim_expires_at_us <= ^now_us,
          order_by: [asc: task.created_at_us, asc: task.task_id],
          limit: 1

      config.repo.one(query, repo_opts(config))
      |> claim_next_result(config, owner_id, lease_ms, now_us)
    end
  end

  defp claim_next_result(nil, _config, _owner_id, _lease_ms, _now_us), do: :empty

  defp claim_next_result(%TaskRow{} = row, config, owner_id, lease_ms, now_us) do
    case claim_serialized_row(config, row, owner_id, lease_ms, now_us) do
      :unavailable -> :empty
      {:deferred, _remaining_ms} -> :empty
      claimed -> claimed
    end
  end

  defp claim_serialized_row(config, %TaskRow{} = row, owner_id, lease_ms, now_us) do
    with {:ok, snapshot} <- decode_task_row(row),
         {:ok, now} <- Timestamp.format(now_us) do
      retry_availability = Snapshot.retry_availability(snapshot, now)

      cond do
        ProtocolTask.terminal?(snapshot.task) ->
          :unavailable

        is_nil(snapshot.work) ->
          :unavailable

        match?({:deferred, _remaining_ms}, retry_availability) ->
          retry_availability

        retry_availability == :invalid ->
          {:error, :invalid_retry_availability}

        claim_live?(row, now_us) ->
          :unavailable

        true ->
          persist_new_claim(config, row, snapshot, owner_id, lease_ms, now_us)
      end
    end
  end

  defp persist_new_claim(config, row, snapshot, owner_id, lease_ms, now_us) do
    with {:ok, expires_at_us} <- Timestamp.add_milliseconds(now_us, lease_ms) do
      token = Ecto.UUID.generate()
      generation = row.lease_generation + 1

      query =
        from task in TaskRow,
          where: task.task_id == ^row.task_id,
          where: task.lease_generation == ^row.lease_generation

      {count, nil} =
        config.repo.update_all(
          query,
          [
            set: [
              claim_owner: owner_id,
              claim_token: token,
              lease_generation: generation,
              claim_expires_at_us: expires_at_us
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
        expires_at_us: expires_at_us
      }

      {:ok, snapshot, lease}
    end
  end

  defp renew_serialized_claim(config, %Lease{task_id: task_id} = lease, lease_ms) do
    case fetch_row_in_transaction(config, task_id) do
      nil ->
        {:error, :stale_lease}

      %TaskRow{} = row ->
        with {:ok, _snapshot} <- decode_task_row(row),
             {:ok, now_us} <- database_now_us(config),
             :ok <- authorize_worker(config, lease, row, task_id, now_us),
             {:ok, candidate_us} <- Timestamp.add_milliseconds(now_us, lease_ms),
             {:ok, expires_at_us} <- renewal_expiry(candidate_us, row.claim_expires_at_us) do
          query =
            from task in TaskRow,
              where: task.task_id == ^task_id,
              where: task.claim_token == ^lease.token,
              where: task.lease_generation == ^lease.generation,
              where: task.claim_expires_at_us == ^lease.expires_at_us

          {count, nil} =
            config.repo.update_all(
              query,
              [set: [claim_expires_at_us: expires_at_us]],
              repo_opts(config)
            )

          ensure_one!(count, :renew_update_lost)
          {:ok, %{lease | expires_at_us: expires_at_us}}
        else
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp renew_serialized_claim(_config, _lease, _lease_ms), do: {:error, :stale_lease}

  defp renewal_expiry(candidate_us, current_us) when candidate_us != current_us,
    do: {:ok, candidate_us}

  defp renewal_expiry(_candidate_us, current_us), do: Timestamp.successor(current_us)

  defp release_serialized_claim(config, %Lease{task_id: task_id} = lease) do
    case fetch_row_in_transaction(config, task_id) do
      nil ->
        {:error, :stale_lease}

      %TaskRow{} = row ->
        with {:ok, _snapshot} <- decode_task_row(row),
             true <- lease_identity_matches?(config, lease, row, task_id) do
          query =
            from task in TaskRow,
              where: task.task_id == ^task_id,
              where: task.claim_token == ^lease.token,
              where: task.lease_generation == ^lease.generation,
              where: task.claim_expires_at_us == ^lease.expires_at_us

          {count, nil} =
            config.repo.update_all(
              query,
              [set: [claim_owner: nil, claim_token: nil, claim_expires_at_us: nil]],
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

  defp release_serialized_claim(_config, _lease), do: {:error, :stale_lease}

  defp reap_serialized_batch(config) do
    with {:ok, now_us} <- database_now_us(config) do
      query =
        from task in TaskRow,
          where: not is_nil(task.expires_at_us),
          where: task.expires_at_us <= ^now_us,
          order_by: [asc: task.expires_at_us, asc: task.task_id],
          limit: ^config.reap_batch_size

      rows = config.repo.all(query, repo_opts(config))

      with :ok <- validate_reap_rows(rows) do
        delete_reap_rows(config, rows)
      end
    end
  end

  defp delete_reap_rows(config, rows) do
    task_ids = Enum.map(rows, & &1.task_id)

    if task_ids != [] do
      delete_query = from task in TaskRow, where: task.task_id in ^task_ids
      {count, nil} = config.repo.delete_all(delete_query, repo_opts(config))
      ensure_count!(count, length(task_ids), :reap_delete_lost)
    end

    {:ok, task_ids}
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

  defp transition_serialized(config, task_id, expected_revision, event, authority) do
    case fetch_row_in_transaction(config, task_id) do
      nil ->
        :not_found

      %TaskRow{} = row ->
        with :ok <- authorize_request_scope(authority, row),
             {:ok, snapshot} <- decode_task_row(row),
             {:ok, now_us} <- database_now_us(config),
             :ok <- authorize_serialized_transition(config, authority, row, task_id, now_us),
             :ok <- Event.validate(event) do
          apply_or_replay(config, row, snapshot, expected_revision, event, now_us)
        end
    end
  end

  defp authorize_request_scope({:request, %Access{encoded_scope: encoded_scope}}, row) do
    if scope_matches?(row, encoded_scope), do: :ok, else: :not_found
  end

  defp authorize_request_scope({:worker, %Lease{}}, _row), do: :ok

  defp authorize_serialized_transition(
         _config,
         {:request, %Access{}},
         _row,
         _task_id,
         _now_us
       ),
       do: :ok

  defp authorize_serialized_transition(config, {:worker, lease}, row, task_id, now_us),
    do: authorize_worker(config, lease, row, task_id, now_us)

  defp apply_or_replay(config, row, snapshot, expected_revision, event, now_us) do
    case fetch_event_row(config, row.task_id, event.id) do
      %EventRow{} = event_row ->
        replay_event(config, event_row, event, snapshot, row.task_id)

      nil when snapshot.revision != expected_revision ->
        {:conflict, snapshot}

      nil ->
        apply_new_event(config, row, snapshot, event, now_us)
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

  defp apply_new_event(config, row, snapshot, event, now_us) do
    with {:ok, committed_at} <- monotonic_timestamp(snapshot.task.last_updated_at, now_us),
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
         {:ok, encoded_event} <- Persistence.encode_json(Event.to_map(event)),
         {:ok, committed_at_us} <- Timestamp.parse(transition.committed_at) do
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
              created_at_us: projected.created_at_us,
              expires_at_us: projected.expires_at_us,
              retry_at_us: projected.retry_at_us
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
              event: encoded_event,
              event_kind: Atom.to_string(event.kind),
              event_revision: transition.event_revision,
              committed_at_us: committed_at_us,
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

  defp history_consistent(config, task_id, encoded_scope) do
    case fetch_row_in_transaction(config, task_id) do
      nil ->
        :not_found

      %TaskRow{} = row ->
        history_row_result(config, row, task_id, encoded_scope)
    end
  end

  defp history_row_result(config, row, task_id, encoded_scope) do
    if scope_matches?(row, encoded_scope) do
      validated_history(config, row, task_id)
    else
      :not_found
    end
  end

  defp validated_history(config, row, task_id) do
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

  defp validate_ledger(%Snapshot{} = snapshot, records, task_id) do
    case LedgerValidator.validate(snapshot, records, task_id) do
      :ok -> :ok
      {:error, reason} -> {:error, {:corrupt_store, task_id, reason}}
    end
  end

  defp validate_event_task_id(%{task_id: task_id}, task_id), do: :ok
  defp validate_event_task_id(_record, _task_id), do: {:error, :event_task_id_projection_mismatch}

  defp authorize_worker(config, %Lease{} = lease, row, task_id, now_us) do
    if lease_identity_matches?(config, lease, row, task_id) and now_us < lease.expires_at_us,
      do: :ok,
      else: {:error, :stale_lease}
  end

  defp authorize_worker(_config, _lease, _row, _task_id, _now_us),
    do: {:error, :stale_lease}

  defp lease_identity_matches?(config, %Lease{} = lease, %TaskRow{} = row, task_id) do
    lease.store_identity == config.identity and lease.task_id == task_id and
      lease.owner_id == row.claim_owner and lease.token == row.claim_token and
      lease.generation == row.lease_generation and
      lease.expires_at_us == row.claim_expires_at_us
  end

  defp claim_live?(%TaskRow{claim_expires_at_us: nil}, _now_us), do: false

  defp claim_live?(%TaskRow{claim_expires_at_us: expires_at_us}, now_us),
    do: now_us < expires_at_us

  defp database_now_us(config) do
    sql = """
    SELECT
      CAST(strftime('%s', 'now') AS INTEGER) * 1000000 +
      CAST(substr(strftime('%f', 'now'), 4, 3) AS INTEGER) * 1000
    """

    case Ecto.Adapters.SQL.query(config.repo, sql, [], timeout: config.timeout) do
      {:ok, %{rows: [[now_us]]}} -> Timestamp.bounded(now_us)
      {:ok, other} -> {:error, {:invalid_database_clock_result, other}}
      {:error, reason} -> normalize_database_error(reason, :database_clock_failed)
    end
  end

  defp monotonic_timestamp(last_updated_at, now_us) do
    with {:ok, last_updated_us} <- Timestamp.parse(last_updated_at),
         {:ok, committed_at_us} <- monotonic_microseconds(last_updated_us, now_us) do
      Timestamp.format(committed_at_us)
    end
  end

  defp monotonic_microseconds(last_updated_us, now_us) when now_us > last_updated_us,
    do: {:ok, now_us}

  defp monotonic_microseconds(last_updated_us, _now_us), do: Timestamp.successor(last_updated_us)

  defp transact_read(config, function) do
    if config.repo.in_transaction?(),
      do: database_call(function),
      else: transact(config, :deferred, function)
  end

  defp transact_write(config, function) do
    if config.repo.in_transaction?(),
      do: {:error, :nested_write_transaction_unsupported},
      else: transact(config, :immediate, function)
  end

  defp transact(config, mode, function) do
    rollback_marker = make_ref()

    case config.repo.transact(
           fn -> transaction_result(function.(), rollback_marker) end,
           mode: mode,
           timeout: config.timeout
         ) do
      {:ok, result} -> result
      {:error, {^rollback_marker, reason}} -> {:error, reason}
      {:error, reason} -> normalize_transaction_error(reason)
    end
  rescue
    exception -> normalize_database_exception(exception)
  catch
    kind, reason -> {:error, {:database_exit, kind, reason, __STACKTRACE__}}
  end

  defp transaction_result({:error, reason}, rollback_marker),
    do: {:error, {rollback_marker, reason}}

  defp transaction_result(result, _rollback_marker), do: {:ok, result}

  defp normalize_transaction_error(reason) do
    if database_busy?(reason), do: {:error, :database_busy}, else: {:error, reason}
  end

  defp database_call(function) do
    function.()
  rescue
    exception -> normalize_database_exception(exception)
  catch
    kind, reason -> {:error, {:database_exit, kind, reason, __STACKTRACE__}}
  end

  defp normalize_database_exception(exception) do
    if database_busy?(exception),
      do: {:error, :database_busy},
      else: {:error, {:database_error, exception}}
  end

  defp normalize_database_error(reason, tag) do
    if database_busy?(reason), do: {:error, :database_busy}, else: {:error, {tag, reason}}
  end

  defp database_busy?(reason) do
    message = reason |> inspect() |> String.downcase()

    Enum.any?(
      ["database is locked", "database is busy", "sqlite_busy", "busy timeout"],
      &String.contains?(message, &1)
    )
  end

  defp repo_opts(%Config{timeout: timeout}), do: [timeout: timeout]

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

    case database_call(fn -> config.repo.all(query, repo_opts(config)) end) do
      rows when is_list(rows) ->
        errors = Enum.flat_map(rows, &audit_errors(config, &1))
        next_cursor = if length(rows) == limit, do: List.last(rows).task_id, else: nil
        {:ok, %{checked: length(rows), errors: errors, next_cursor: next_cursor}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp audit_errors(config, row) do
    case audit_one(config, row.task_id) do
      :ok -> []
      {:error, reason} -> [%{task_id: row.task_id, reason: reason}]
    end
  end

  defp audit_one(config, task_id) do
    transact_read(config, fn ->
      case fetch_row_in_transaction(config, task_id) do
        nil -> :ok
        %TaskRow{} = row -> audit_consistent_row(config, row)
      end
    end)
  end

  defp audit_consistent_row(config, row) do
    with {:ok, snapshot} <- decode_task_row(row),
         {:ok, records} <- load_history(config, row.task_id) do
      validate_ledger(snapshot, records, row.task_id)
    end
  end

  defp check_file_backed(config) do
    case sql_query(config, "PRAGMA database_list") do
      {:ok, %{rows: rows}} ->
        validate_database_list(rows)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_database_list(rows) do
    main =
      Enum.find(rows, fn
        [_sequence, "main", _path] -> true
        _row -> false
      end)

    case main do
      [_sequence, "main", path] when is_binary(path) and path != "" -> :ok
      _memory_or_missing -> {:error, :sqlite_database_must_be_file_backed}
    end
  end

  defp check_schema_checked_out(config) do
    with :ok <- check_file_backed(config),
         :ok <- check_journal_mode(config),
         :ok <- check_foreign_keys(config) do
      check_schema_version(config)
    end
  end

  defp check_journal_mode(config) do
    case sql_query(config, "PRAGMA journal_mode") do
      {:ok, %{rows: [[mode]]}} when is_binary(mode) ->
        if String.downcase(mode) == "wal", do: :ok, else: {:error, {:wal_required, mode}}

      {:ok, other} ->
        {:error, {:invalid_journal_mode_result, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp check_foreign_keys(config) do
    case sql_query(config, "PRAGMA foreign_keys") do
      {:ok, %{rows: [[1]]}} -> :ok
      {:ok, %{rows: [[value]]}} -> {:error, {:foreign_keys_required, value}}
      {:ok, other} -> {:error, {:invalid_foreign_keys_result, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_schema_version(config) do
    expected_version = Migration.current_version()

    query =
      from metadata in MetadataRow,
        where: metadata.singleton == 1,
        select: metadata.schema_version

    case config.repo.one(query, repo_opts(config)) do
      ^expected_version -> :ok
      nil -> {:error, :schema_metadata_missing}
      version -> {:error, {:unsupported_schema_version, version}}
    end
  end

  defp sql_query(config, sql) do
    case Ecto.Adapters.SQL.query(config.repo, sql, [], timeout: config.timeout) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> normalize_database_error(reason, :database_query_failed)
    end
  end
end
