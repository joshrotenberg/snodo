defmodule MCP.Extensions.Tasks.LedgerValidatorTest do
  use ExUnit.Case, async: true

  alias MCP.Extensions.Tasks.Event
  alias MCP.Extensions.Tasks.LedgerValidator
  alias MCP.Extensions.Tasks.RetryPolicy
  alias MCP.Extensions.Tasks.Snapshot
  alias MCP.Extensions.Tasks.Task, as: ProtocolTask
  alias MCP.Extensions.Tasks.Transition
  alias MCP.Extensions.Tasks.Work

  @created_at "2026-08-25T10:00:00.000Z"
  @first_commit "2026-08-25T10:00:01.000Z"
  @second_commit "2026-08-25T10:00:02.000Z"

  test "a valid retry ledger agrees with its persisted policy and final snapshot" do
    {snapshot, records} = scheduled_retry_ledger()

    assert :ok = LedgerValidator.validate(snapshot, records, snapshot.task.id)
  end

  test "event kinds and effects must agree semantically" do
    {retry_snapshot, [retry_record]} = scheduled_retry_ledger()

    assert {:error, :event_effect_mismatch} =
             LedgerValidator.validate(
               retry_snapshot,
               [%{retry_record | effects: %{}}],
               retry_snapshot.task.id
             )

    initial = Snapshot.new(task("input-effects"), work("input-effects"))

    requested =
      event!(
        Event.input_requested(
          "answer",
          %{"method" => "elicitation/create", "params" => %{}},
          id: "request-event"
        )
      )

    {requested_snapshot, request_record} = transition_record(initial, requested, @first_commit)

    accepted =
      event!(
        Event.input_responses_accepted(
          %{
            "answer" => %{"value" => 42},
            "not-outstanding" => %{"value" => "ignored"}
          },
          id: "response-event"
        )
      )

    {final_snapshot, response_record} =
      transition_record(requested_snapshot, accepted, @second_commit)

    records = [request_record, response_record]
    assert :ok = LedgerValidator.validate(final_snapshot, records, final_snapshot.task.id)

    forged_response =
      put_in(response_record, [:effects, :accepted_input_responses, "answer"], %{
        "value" => "forged"
      })

    assert {:error, :event_effect_mismatch} =
             LedgerValidator.validate(
               final_snapshot,
               [request_record, forged_response],
               final_snapshot.task.id
             )
  end

  test "retry effects must match sequence, exact policy delay, and commit timestamp" do
    {snapshot, [record]} = scheduled_retry_ledger()

    forged_policy = RetryPolicy.new!([999, 3_000])
    forged_work = %{snapshot.work | retry_policy: forged_policy}

    assert {:error, :retry_effect_policy_mismatch} =
             LedgerValidator.validate(
               %{snapshot | work: forged_work},
               [record],
               snapshot.task.id
             )

    wrong_count = put_in(record, [:effects, :retry, :retry_count], 2)

    assert {:error, :retry_effect_sequence_mismatch} =
             LedgerValidator.validate(snapshot, [wrong_count], snapshot.task.id)

    wrong_delay = put_in(record, [:effects, :retry, :delay_ms], 999)

    assert {:error, :retry_effect_policy_mismatch} =
             LedgerValidator.validate(snapshot, [wrong_delay], snapshot.task.id)

    wrong_timestamp =
      put_in(record, [:effects, :retry, :retry_at], "2026-08-25T10:00:09.000Z")

    assert {:error, :retry_effect_timestamp_mismatch} =
             LedgerValidator.validate(snapshot, [wrong_timestamp], snapshot.task.id)
  end

  test "retry history must agree with final count, failure, and availability" do
    {snapshot, [record]} = scheduled_retry_ledger()

    forged_failure = %{
      snapshot
      | last_failure: %{
          "error" => error("different"),
          "statusMessage" => "retry requested"
        }
    }

    assert {:error, :retry_snapshot_failure_mismatch} =
             LedgerValidator.validate(forged_failure, [record], snapshot.task.id)

    forged_availability = %{snapshot | retry_at: "2026-08-25T10:00:03.000Z"}

    assert {:error, :retry_snapshot_availability_mismatch} =
             LedgerValidator.validate(forged_availability, [record], snapshot.task.id)

    forged_terminal_task = %{
      snapshot.task
      | status: :failed,
        status_message: "forged terminal state",
        error: error("forged terminal state")
    }

    assert {:error, :event_ledger_final_snapshot_mismatch} =
             LedgerValidator.validate(
               %{snapshot | task: forged_terminal_task, retry_at: nil},
               [record],
               snapshot.task.id
             )

    completed_event = event!(Event.completed(%{"ok" => true}, id: "forged-terminal"))

    forged_record = %{
      record
      | event: completed_event,
        effects: %{}
    }

    assert {:error, :retry_snapshot_count_mismatch} =
             LedgerValidator.validate(snapshot, [forged_record], snapshot.task.id)
  end

  test "exhaustion must match the policy and terminal snapshot" do
    initial = Snapshot.new(task("exhausted"), work("exhausted"))

    retry =
      event!(Event.retry_requested(error("terminal"), "no retries remain", id: "exhaust-event"))

    {snapshot, record} = transition_record(initial, retry, @first_commit)
    assert :ok = LedgerValidator.validate(snapshot, [record], snapshot.task.id)

    forged_event =
      event!(Event.retry_requested(error("forged"), "no retries remain", id: "exhaust-event"))

    assert {:error, :retry_exhaustion_snapshot_mismatch} =
             LedgerValidator.validate(
               snapshot,
               [%{record | event: forged_event}],
               snapshot.task.id
             )

    forged_count = put_in(record, [:effects, :retry, :retry_count], 1)

    assert {:error, :retry_effect_sequence_mismatch} =
             LedgerValidator.validate(snapshot, [forged_count], snapshot.task.id)
  end

  test "the ledger binds every row and final event timestamp to the final snapshot" do
    initial = Snapshot.new(task("final-state"), work("final-state"))
    completed = event!(Event.completed(%{"ok" => true}, id: "complete-final"))
    {snapshot, record} = transition_record(initial, completed, @first_commit)

    assert {:error, :event_ledger_task_id_mismatch} =
             LedgerValidator.validate(
               snapshot,
               [%{record | task_id: "forged-task"}],
               snapshot.task.id
             )

    forged_task = %{snapshot.task | result: %{"ok" => false}}

    assert {:error, :event_ledger_final_snapshot_mismatch} =
             LedgerValidator.validate(
               %{snapshot | task: forged_task},
               [record],
               snapshot.task.id
             )

    forged_timestamp_task = %{
      snapshot.task
      | last_updated_at: "2026-08-25T10:00:01.001Z"
    }

    assert {:error, :event_ledger_final_timestamp_mismatch} =
             LedgerValidator.validate(
               %{snapshot | task: forged_timestamp_task},
               [record],
               snapshot.task.id
             )
  end

  defp scheduled_retry_ledger do
    retry_policy = RetryPolicy.new!([1_500, 3_000])
    work = Work.new!("retry-ledger", "test/work", %{}, retry_policy: retry_policy)
    initial = Snapshot.new(task("retry-ledger"), work)

    retry =
      event!(
        Event.retry_requested(
          error("temporary"),
          "retry requested",
          id: "retry-event"
        )
      )

    {snapshot, record} = transition_record(initial, retry, @first_commit)
    {snapshot, [record]}
  end

  defp transition_record(snapshot, event, committed_at) do
    assert {:ok, %Transition{outcome: :applied} = transition} =
             Transition.apply(snapshot, event, committed_at)

    record = %{
      task_id: snapshot.task.id,
      event: event,
      effects: transition.effects,
      revision: transition.event_revision,
      committed_at: transition.committed_at
    }

    {transition.snapshot, record}
  end

  defp task(id) do
    ProtocolTask.new!(
      id: id,
      created_at: @created_at,
      ttl_ms: nil,
      poll_interval_ms: 50,
      status_message: "accepted"
    )
  end

  defp work(id), do: Work.new!(id, "test/work", %{"taskId" => id})
  defp error(message), do: %{"code" => -32_603, "message" => message}
  defp event!({:ok, %Event{} = event}), do: event
end
