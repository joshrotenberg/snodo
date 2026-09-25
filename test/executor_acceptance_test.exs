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

    assert_receive {:snodoecution, ^executor, ^first_ref, {:scope, 1}, {:completed, :first}}
    assert_receive {:entered, :second, second_worker, _cancellation}
    refute_receive {:entered, :third, _worker, _cancellation}, 20
    send(second_worker, :release)

    assert_receive {:snodoecution, ^executor, ^second_ref, {:scope, 2}, {:completed, :second}}
    assert_receive {:entered, :third, third_worker, _cancellation}
    send(third_worker, :release)

    assert_receive {:snodoecution, ^executor, ^third_ref, {:scope, 3}, {:completed, :third}}
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

    assert_receive {:snodoecution, ^executor, ^first_ref, {:connection_a, 7}, {:completed, :done}}

    assert_receive {:snodoecution, ^executor, ^other_scope_ref, {:connection_b, 7},
                    {:completed, :done}}

    assert {:ok, reused_ref} = Executor.submit(executor, {:connection_a, 7}, fn _ -> :reused end)

    assert_receive {:snodoecution, ^executor, ^reused_ref, {:connection_a, 7},
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

    assert_receive {:snodoecution, ^executor, ^queued_ref, :queued_cancel,
                    {:cancelled, "cancelled while queued"}}

    refute_receive :queued_job_started, 20
    assert Executor.stats(executor).queued == 0
    assert executor |> :sys.get_state() |> Map.fetch!(:queue) |> :queue.len() == 0

    assert :ok = Executor.cancel(executor, :cancel_me, "caller stopped")

    assert_receive {:snodoecution, ^executor, ^execution_ref, :cancel_me,
                    {:cancelled, "caller stopped"}}

    assert Snodo.Cancellation.cancelled?(cancellation)
    refute_receive {:snodoecution, ^executor, ^execution_ref, :cancel_me, _outcome}, 30
    assert {:error, :not_found} = Executor.cancel(executor, :cancel_me)
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

    assert {:ok, next_ref} = Executor.submit(executor, :next, fn _ -> :next end)
    assert_receive {:timed_started, cancellation}

    assert_receive {:snodoecution, ^executor, ^timed_ref, :timed, {:timed_out, 30}}, 500
    assert Snodo.Cancellation.cancelled?(cancellation)
    assert_receive {:snodoecution, ^executor, ^next_ref, :next, {:completed, :next}}, 500
    refute_receive {:snodoecution, ^executor, ^timed_ref, :timed, _outcome}, 30

    assert {:ok, failed_ref} =
             Executor.submit(executor, :crashes, fn _cancellation ->
               Process.exit(self(), :kill)
             end)

    assert_receive {:snodoecution, ^executor, ^failed_ref, :crashes, {:failed, :killed}}, 500
    refute_receive {:snodoecution, ^executor, ^failed_ref, :crashes, _outcome}, 30

    assert {:ok, reused_ref} = Executor.submit(executor, :crashes, fn _ -> :recovered end)

    assert_receive {:snodoecution, ^executor, ^reused_ref, :crashes, {:completed, :recovered}}
  end

  test "reply-owner death cancels running and queued work before reusing capacity" do
    {:ok, executor} =
      start_supervised({Executor, max_concurrency: 1, max_queue: 1, default_timeout: :infinity})

    test_process = self()

    owner =
      spawn(fn ->
        {:ok, _running_ref} =
          Executor.submit(executor, :owner_running, fn cancellation ->
            send(test_process, {:owner_job_started, self(), cancellation})
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
    worker_monitor = Process.monitor(worker)
    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 500
    assert Snodo.Cancellation.cancelled?(cancellation)
    refute_receive :orphan_queue_started, 30
    assert Executor.stats(executor).running == 0
    assert Executor.stats(executor).queued == 0

    assert {:ok, recovered_ref} = Executor.submit(executor, :after_owner, fn _ -> :available end)

    assert_receive {:snodoecution, ^executor, ^recovered_ref, :after_owner,
                    {:completed, :available}}
  end
end
