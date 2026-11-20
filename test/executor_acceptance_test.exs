defmodule Snodo.Server.ExecutorAcceptanceTest do
  use ExUnit.Case, async: true

  alias Snodo.Server.Executor

  test "bounds concurrency, queues in admission order, and rejects excess work" do
    {:ok, executor} =
      start_supervised({Executor, max_concurrency: 1, max_queue: 2, default_timeout: :infinity})

    owner = self()

    blocking = fn label ->
      fn cancellation ->
        send(owner, {:entered, label, self(), cancellation})

        receive do
          :release -> label
        end
      end
    end

    assert {:ok, first_ref} = Executor.submit(executor, {:scope, 1}, blocking.(:first))
    assert_receive {:entered, :first, first_worker, _cancellation}

    assert {:ok, second_ref} = Executor.submit(executor, {:scope, 2}, blocking.(:second))
    assert {:ok, third_ref} = Executor.submit(executor, {:scope, 3}, blocking.(:third))
    assert {:error, :overloaded} = Executor.submit(executor, {:scope, 4}, blocking.(:fourth))

    assert Executor.stats(executor) == %{
             running: 1,
             queued: 2,
             max_concurrency: 1,
             max_queue: 2
           }

    refute_receive {:entered, :second, _worker, _cancellation}, 20
    refute_receive {:entered, :third, _worker, _cancellation}, 20
    send(first_worker, :release)

    assert_receive {:mcp_execution, ^executor, ^first_ref, {:scope, 1}, {:completed, :first}}
    assert_receive {:entered, :second, second_worker, _cancellation}
    refute_receive {:entered, :third, _worker, _cancellation}, 20
    send(second_worker, :release)

    assert_receive {:mcp_execution, ^executor, ^second_ref, {:scope, 2}, {:completed, :second}}
    assert_receive {:entered, :third, third_worker, _cancellation}
    send(third_worker, :release)

    assert_receive {:mcp_execution, ^executor, ^third_ref, {:scope, 3}, {:completed, :third}}
    assert Executor.stats(executor).running == 0
    assert Executor.stats(executor).queued == 0
  end

  test "keys are scope-sensitive, duplicate while admitted, and reusable after completion" do
    {:ok, executor} =
      start_supervised({Executor, max_concurrency: 2, max_queue: 0, default_timeout: :infinity})

    owner = self()

    work = fn cancellation ->
      send(owner, {:started, self(), cancellation})

      receive do
        :release -> :done
      end
    end

    assert {:ok, first_ref} = Executor.submit(executor, {:connection_a, 7}, work)
    assert {:error, :duplicate_key} = Executor.submit(executor, {:connection_a, 7}, work)
    assert {:ok, other_scope_ref} = Executor.submit(executor, {:connection_b, 7}, work)

    assert_receive {:started, first_worker, _first_token}
    assert_receive {:started, second_worker, _second_token}
    send(first_worker, :release)
    send(second_worker, :release)

    assert_receive {:mcp_execution, ^executor, ^first_ref, {:connection_a, 7},
                    {:completed, :done}}

    assert_receive {:mcp_execution, ^executor, ^other_scope_ref, {:connection_b, 7},
                    {:completed, :done}}

    assert {:ok, reused_ref} = Executor.submit(executor, {:connection_a, 7}, fn _ -> :reused end)

    assert_receive {:mcp_execution, ^executor, ^reused_ref, {:connection_a, 7},
                    {:completed, :reused}}
  end

  test "cancellation sets the cooperative token and emits exactly one terminal outcome" do
    {:ok, executor} =
      start_supervised({Executor, max_concurrency: 1, max_queue: 1, default_timeout: :infinity})

    owner = self()

    assert {:ok, execution_ref} =
             Executor.submit(executor, :cancel_me, fn cancellation ->
               send(owner, {:cancellable_started, self(), cancellation})

               receive do
                 :never -> :unexpected
               end
             end)

    assert_receive {:cancellable_started, _worker, cancellation}
    refute Snodo.Cancellation.cancelled?(cancellation)

    assert {:ok, queued_ref} =
             Executor.submit(executor, :queued_cancel, fn _cancellation ->
               send(owner, :queued_job_started)
             end)

    assert :ok = Executor.cancel(executor, :queued_cancel, "cancelled while queued")

    assert_receive {:mcp_execution, ^executor, ^queued_ref, :queued_cancel,
                    {:cancelled, "cancelled while queued"}}

    refute_receive :queued_job_started, 20
    assert Executor.stats(executor).queued == 0
    state = :sys.get_state(executor)
    assert :queue.is_empty(state.queue)
    assert state.queue_timer == nil
    assert :gb_sets.is_empty(state.queue_deadlines)

    assert :ok = Executor.cancel(executor, :cancel_me, "caller stopped")

    assert_receive {:mcp_execution, ^executor, ^execution_ref, :cancel_me,
                    {:cancelled, "caller stopped"}}

    assert Snodo.Cancellation.cancelled?(cancellation)
    refute_receive {:mcp_execution, ^executor, ^execution_ref, :cancel_me, _outcome}, 30
    assert {:error, :not_found} = Executor.cancel(executor, :cancel_me)
  end

  test "one timer expires queued work by deadline while the worker stays occupied" do
    executor = start_supervised!({Executor, max_concurrency: 1, max_queue_wait: 60_000})
    owner = self()

    assert {:ok, _ref} =
             Executor.submit(executor, :blocker, fn _ -> Process.sleep(:infinity) end)

    work = fn _ -> send(owner, :queued_job_started) end
    assert {:ok, head_ref} = Executor.submit(executor, :head, work, timeout: :infinity)
    assert {:ok, tail_ref} = Executor.submit(executor, :tail, work, timeout: 30_000)
    expire_next_queued_job(executor, tail_ref)
    assert_receive {:mcp_execution, ^executor, ^tail_ref, :tail, :queue_timed_out}
    assert %{queued: 1, running: 1} = Executor.stats(executor)

    expire_next_queued_job(executor, head_ref)
    assert_receive {:mcp_execution, ^executor, ^head_ref, :head, :queue_timed_out}
    assert %{queued: 0, running: 1} = Executor.stats(executor)

    state = :sys.get_state(executor)
    assert state.queue_timer == nil
    assert :gb_sets.is_empty(state.queue_deadlines)
    assert map_size(state.jobs_by_owner_monitor) == 1
    assert {:error, :not_found} = Executor.cancel(executor, :head)

    assert :ok = Executor.cancel(executor, :blocker)
    assert {:ok, reused} = Executor.submit(executor, :head, fn _ -> :available end)
    assert_receive {:mcp_execution, ^executor, ^reused, :head, {:completed, :available}}
    refute_received :queued_job_started
    refute_received {:mcp_execution, ^executor, ^head_ref, :head, _}
    refute_received {:mcp_execution, ^executor, ^tail_ref, :tail, _}
  end

  test "dequeue checks the deadline even when the timer message has not arrived" do
    executor = start_supervised!({Executor, max_concurrency: 1})
    owner = self()

    assert {:ok, blocker_ref} =
             Executor.submit(executor, :blocker, fn _ ->
               send(owner, {:blocker, self()})

               receive do
                 :release -> :released
               end
             end)

    assert_receive {:blocker, worker}

    assert {:ok, queued_ref} =
             Executor.submit(executor, :queued, fn _ -> send(owner, :queued_job_started) end)

    state = :sys.get_state(executor)
    {_deadline, timer} = state.queue_timer
    Process.cancel_timer(timer)

    # Advance the deadline in both indexes while withholding the timer event.
    :sys.replace_state(executor, fn state ->
      expired = System.monotonic_time(:millisecond) - 1

      state
      |> put_in([:jobs, queued_ref, :queue_deadline], expired)
      |> Map.put(:queue_deadlines, :gb_sets.from_list([{expired, queued_ref}]))
    end)

    send(worker, :release)
    assert_receive {:mcp_execution, ^executor, ^blocker_ref, :blocker, {:completed, :released}}
    assert_receive {:mcp_execution, ^executor, ^queued_ref, :queued, :queue_timed_out}

    # A stale timer event must not generate a second outcome.
    send(executor, {:timeout, timer, :queue_deadline})
    state = :sys.get_state(executor)
    assert state.queue_timer == nil
    assert state.jobs == %{}
    assert state.jobs_by_key == %{}
    assert state.jobs_by_owner_monitor == %{}
    assert %{queued: 0, running: 0} = Executor.stats(executor)
    refute_received :queued_job_started
    refute_received {:mcp_execution, ^executor, ^queued_ref, :queued, _}
  end

  test "dequeue skips a stale queue entry and starts the next job" do
    executor = start_supervised!({Executor, max_concurrency: 1})

    assert {:ok, _blocker} =
             Executor.submit(executor, :blocker, fn _ -> Process.sleep(:infinity) end)

    assert {:ok, ref} = Executor.submit(executor, :next, fn _ -> :started end)
    stale = make_ref()

    :sys.replace_state(executor, fn state ->
      %{
        state
        | queue: :queue.in_r(stale, state.queue),
          queued: state.queued + 1,
          queue_deadlines:
            :gb_sets.add({state.jobs[ref].queue_deadline, stale}, state.queue_deadlines)
      }
    end)

    assert :ok = Executor.cancel(executor, :blocker)
    assert_receive {:mcp_execution, ^executor, ^ref, :next, {:completed, :started}}
    assert %{running: 0, queued: 0} = Executor.stats(executor)
    state = :sys.get_state(executor)
    assert state.queue_timer == nil
    assert :gb_sets.is_empty(state.queue_deadlines)
  end

  test "a queued job starts with only the remaining request budget" do
    executor = start_supervised!({Executor, max_concurrency: 1})
    owner = self()

    assert {:ok, _blocker} =
             Executor.submit(executor, :blocker, fn _ -> Process.sleep(:infinity) end)

    assert {:ok, queued_ref} =
             Executor.submit(executor, :queued, fn _ ->
               send(owner, :queued_job_started)
               Process.sleep(:infinity)
             end)

    :sys.replace_state(executor, fn state ->
      deadline = System.monotonic_time(:millisecond) + 1_000

      state
      |> move_queue_deadline(queued_ref, deadline)
      |> put_in([:jobs, queued_ref, :deadline], deadline)
    end)

    assert :ok = Executor.cancel(executor, :blocker)
    assert_receive :queued_job_started

    assert_receive {:mcp_execution, ^executor, ^queued_ref, :queued, {:timed_out, 30_000}},
                   3_000
  end

  test "a zero timeout with a free slot expires before dispatch" do
    executor = start_supervised!(Executor)
    owner = self()

    assert {:ok, ref} =
             Executor.submit(executor, :zero, fn _ -> send(owner, :started) end, timeout: 0)

    assert_receive {:mcp_execution, ^executor, ^ref, :zero, {:timed_out, 0}}
    assert %{running: 0, queued: 0} = Executor.stats(executor)
    assert :sys.get_state(executor).jobs == %{}
    refute_received :started
  end

  test "max_queue_wait rejects invalid values" do
    for invalid <- [-1, :default, 1.5] do
      assert_raise ArgumentError,
                   ":max_queue_wait must be a non-negative integer or :infinity",
                   fn ->
                     Executor.init(max_queue_wait: invalid)
                   end
    end
  end

  test "execution deadlines cancel work, suppress late results, and release capacity" do
    {:ok, executor} =
      start_supervised({Executor, max_concurrency: 1, max_queue: 1, default_timeout: 30})

    owner = self()

    assert {:ok, timed_ref} =
             Executor.submit(executor, :timed, fn cancellation ->
               send(owner, {:timed_started, cancellation})
               Process.sleep(:infinity)
             end)

    assert {:ok, next_ref} =
             Executor.submit(executor, :next, fn _ -> :next end, timeout: :infinity)

    assert_receive {:timed_started, cancellation}

    assert_receive {:mcp_execution, ^executor, ^timed_ref, :timed, {:timed_out, 30}}, 500
    assert Snodo.Cancellation.cancelled?(cancellation)
    assert_receive {:mcp_execution, ^executor, ^next_ref, :next, {:completed, :next}}, 500
    refute_receive {:mcp_execution, ^executor, ^timed_ref, :timed, _outcome}, 30

    assert {:ok, failed_ref} =
             Executor.submit(executor, :crashes, fn _cancellation ->
               Process.exit(self(), :kill)
             end)

    assert_receive {:mcp_execution, ^executor, ^failed_ref, :crashes, {:failed, :killed}}, 500
    refute_receive {:mcp_execution, ^executor, ^failed_ref, :crashes, _outcome}, 30

    assert {:ok, reused_ref} = Executor.submit(executor, :crashes, fn _ -> :recovered end)

    assert_receive {:mcp_execution, ^executor, ^reused_ref, :crashes, {:completed, :recovered}}
  end

  test "reply-owner death cancels running and queued work before reusing capacity" do
    {:ok, executor} =
      start_supervised(
        {Executor,
         max_concurrency: 1, max_queue: 1, default_timeout: :infinity, max_queue_wait: 30_000}
      )

    test_process = self()

    owner =
      spawn(fn ->
        {:ok, _running_ref} =
          Executor.submit(executor, :owner_running, fn cancellation ->
            send(test_process, {:owner_job_started, self(), cancellation})

            receive do
              {:ping, from} -> send(from, :pong)
            end

            Process.sleep(:infinity)
          end)

        {:ok, _queued_ref} =
          Executor.submit(executor, :owner_queued, fn _cancellation ->
            send(test_process, :orphan_queue_started)
          end)

        send(test_process, :owner_jobs_submitted)
        Process.sleep(:infinity)
      end)

    assert_receive {:owner_job_started, worker, cancellation}, 500
    assert_receive :owner_jobs_submitted, 500
    assert {_deadline, _timer} = :sys.get_state(executor).queue_timer
    worker_monitor = Process.monitor(worker)
    # A monitor request can be overtaken by the executor's kill, which comes from
    # another process, and then reports :noproc. The worker handles this ping only
    # after the earlier monitor request, so the monitor is in place.
    send(worker, {:ping, self()})
    assert_receive :pong, 500
    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 500
    assert Snodo.Cancellation.cancelled?(cancellation)
    refute_receive :orphan_queue_started, 30
    assert Executor.stats(executor).running == 0
    assert Executor.stats(executor).queued == 0
    state = :sys.get_state(executor)
    assert state.queue_timer == nil
    assert :gb_sets.is_empty(state.queue_deadlines)

    assert {:ok, recovered_ref} = Executor.submit(executor, :after_owner, fn _ -> :available end)

    assert_receive {:mcp_execution, ^executor, ^recovered_ref, :after_owner,
                    {:completed, :available}}
  end

  test "slots are counted per pool and returned when the owner exits" do
    {:ok, executor} = start_supervised({Executor, max_concurrency: 1, max_queue: 0})

    first = spawn_holder()
    second = spawn_holder()

    assert :ok = Executor.acquire_slot(executor, :streams, 2, first)
    assert :ok = Executor.acquire_slot(executor, :streams, 2, second)
    assert {:error, :exhausted} = Executor.acquire_slot(executor, :streams, 2)
    assert :ok = Executor.acquire_slot(executor, :other_streams, 1)
    assert {:error, :exhausted} = Executor.acquire_slot(executor, :other_streams, 1)

    assert {:ok, reference} = Executor.submit(executor, :work, fn _cancellation -> :done end)
    assert_receive {:mcp_execution, ^executor, ^reference, :work, {:completed, :done}}, 500

    monitor = Process.monitor(first)
    Process.exit(first, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^first, :killed}, 500
    assert eventually(fn -> Executor.acquire_slot(executor, :streams, 2) == :ok end)
    assert {:error, :exhausted} = Executor.acquire_slot(executor, :streams, 2)

    monitor = Process.monitor(second)
    send(second, :exit)
    assert_receive {:DOWN, ^monitor, :process, ^second, :normal}, 500
    assert eventually(fn -> Executor.acquire_slot(executor, :streams, 2) == :ok end)
  end

  test "a slot limit must be a positive integer" do
    {:ok, executor} = start_supervised(Executor)
    assert_raise ArgumentError, fn -> Executor.acquire_slot(executor, :streams, 0) end
  end

  defp expire_next_queued_job(executor, ref) do
    %{queue_timer: {deadline, timer}, queue_deadlines: deadlines} = :sys.get_state(executor)
    assert :gb_sets.smallest(deadlines) == {deadline, ref}
    Process.cancel_timer(timer)

    :sys.replace_state(executor, fn state ->
      move_queue_deadline(state, ref, System.monotonic_time(:millisecond) - 1)
    end)

    send(executor, {:timeout, timer, :queue_deadline})
  end

  defp move_queue_deadline(state, ref, deadline) do
    previous = state.jobs[ref].queue_deadline

    state
    |> put_in([:jobs, ref, :queue_deadline], deadline)
    |> Map.update!(:queue_deadlines, fn deadlines ->
      deadlines
      |> then(&:gb_sets.delete({previous, ref}, &1))
      |> then(&:gb_sets.add({deadline, ref}, &1))
    end)
  end

  defp spawn_holder do
    spawn(fn ->
      receive do
        :exit -> :ok
      end
    end)
  end

  defp eventually(check, deadline \\ System.monotonic_time(:millisecond) + 1_000) do
    cond do
      check.() ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        Process.sleep(5)
        eventually(check, deadline)
    end
  end
end
