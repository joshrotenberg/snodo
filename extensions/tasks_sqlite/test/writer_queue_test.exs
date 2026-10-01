defmodule Snodo.Extensions.Tasks.Store.SQLite.WriterQueueTest do
  use ExUnit.Case, async: true

  alias Snodo.Extensions.Tasks.Store.SQLite.WriterQueue

  @max_waiters 100
  @await_ms 2_000

  setup do
    %{key: {__MODULE__, make_ref()}}
  end

  test "grants the slot to waiters in arrival order and hands it on at release", %{key: key} do
    assert {:ok, slot} = WriterQueue.acquire(key, deadline(@await_ms), @max_waiters)

    waiters =
      Enum.map(1..10, fn index ->
        waiter = start_waiter(key, index)
        await_waiting(key, index)
        waiter
      end)

    :ok = WriterQueue.release(slot)

    Enum.each(1..10, fn index ->
      assert_receive {:granted, ^index, waiter}, @await_ms
      assert waiter == Enum.at(waiters, index - 1)
      refute_received {:granted, _other, _waiter}
      send(waiter, :release)
    end)
  end

  test "a writer that releases and acquires again waits behind the queue", %{key: key} do
    assert {:ok, slot} = WriterQueue.acquire(key, deadline(@await_ms), @max_waiters)
    _waiter = start_waiter(key, :waiter)
    await_waiting(key, 1)

    :ok = WriterQueue.release(slot)
    again = Task.async(fn -> WriterQueue.acquire(key, deadline(@await_ms), @max_waiters) end)

    assert_receive {:granted, :waiter, waiter}, @await_ms
    await_waiting(key, 1)
    assert Task.yield(again, 0) == nil
    send(waiter, :release)

    assert {:ok, slot} = Task.await(again, @await_ms)
    :ok = WriterQueue.release(slot)
  end

  test "a holder that exits releases the slot to the next waiter", %{key: key} do
    holder = start_waiter(key, :holder)
    assert_receive {:granted, :holder, ^holder}, @await_ms
    _waiter = start_waiter(key, :next)
    await_waiting(key, 1)

    Process.exit(holder, :kill)

    assert_receive {:granted, :next, _waiter}, @await_ms
  end

  test "a waiter that exits leaves the queue", %{key: key} do
    assert {:ok, slot} = WriterQueue.acquire(key, deadline(@await_ms), @max_waiters)
    dead = start_waiter(key, :dead)
    await_waiting(key, 1)
    _live = start_waiter(key, :live)
    await_waiting(key, 2)

    Process.exit(dead, :kill)
    await_waiting(key, 1)
    :ok = WriterQueue.release(slot)

    assert_receive {:granted, :live, _waiter}, @await_ms
    refute_received {:granted, :dead, _waiter}
  end

  test "a writer whose deadline has passed takes only a free slot", %{key: key} do
    assert {:ok, slot} = WriterQueue.acquire(key, deadline(-10), @max_waiters)
    assert {:error, :database_busy} = WriterQueue.acquire(key, deadline(-10), @max_waiters)
    assert WriterQueue.waiting(key) == 0
    :ok = WriterQueue.release(slot)
  end

  test "a writer arriving at a full queue is refused at once", %{key: key} do
    assert {:ok, slot} = WriterQueue.acquire(key, deadline(@await_ms), 2)
    _first = start_waiter(key, :first, 2)
    await_waiting(key, 1)
    _second = start_waiter(key, :second, 2)
    await_waiting(key, 2)

    started = System.monotonic_time(:millisecond)
    assert {:error, :database_busy} = WriterQueue.acquire(key, deadline(@await_ms), 2)
    assert System.monotonic_time(:millisecond) - started < @await_ms
    assert WriterQueue.waiting(key) == 2

    :ok = WriterQueue.release(slot)
    assert_receive {:granted, :first, _waiter}, @await_ms
  end

  test "a waiter whose deadline passes leaves the queue with :database_busy", %{key: key} do
    assert {:ok, slot} = WriterQueue.acquire(key, deadline(@await_ms), @max_waiters)

    started = System.monotonic_time(:millisecond)
    assert {:error, :database_busy} = WriterQueue.acquire(key, deadline(50), @max_waiters)
    assert System.monotonic_time(:millisecond) - started >= 50
    assert WriterQueue.waiting(key) == 0

    _waiter = start_waiter(key, :after_timeout)
    await_waiting(key, 1)
    :ok = WriterQueue.release(slot)
    assert_receive {:granted, :after_timeout, _waiter}, @await_ms
  end

  test "a slot granted at the deadline is handed on", %{key: key} do
    holder = start_waiter(key, :holder)
    assert_receive {:granted, :holder, ^holder}, @await_ms

    # The holder releases as the waiter's deadline passes. Whichever happens
    # first, the waiter returns :database_busy and the slot is free afterwards.
    late = Task.async(fn -> WriterQueue.acquire(key, deadline(20), @max_waiters) end)
    await_waiting(key, 1)
    send(holder, :release)

    case Task.await(late, @await_ms) do
      {:ok, slot} -> :ok = WriterQueue.release(slot)
      {:error, :database_busy} -> :ok
    end

    assert {:ok, slot} = WriterQueue.acquire(key, deadline(@await_ms), @max_waiters)
    :ok = WriterQueue.release(slot)
  end

  test "an exited holder does not hold the slot after a waiter times out", %{key: key} do
    holder = start_waiter(key, :holder)
    assert_receive {:granted, :holder, ^holder}, @await_ms
    assert {:error, :database_busy} = WriterQueue.acquire(key, deadline(10), @max_waiters)

    Process.exit(holder, :kill)
    assert {:ok, slot} = WriterQueue.acquire(key, deadline(@await_ms), @max_waiters)
    :ok = WriterQueue.release(slot)
  end

  test "the queue for an anonymous dynamic repo stops with it" do
    repo = spawn(fn -> Process.sleep(:infinity) end)
    key = {__MODULE__, repo}
    assert {:ok, slot} = WriterQueue.acquire(key, deadline(@await_ms), @max_waiters)
    {:ok, queue} = WriterQueue.Registry.lookup(key)
    monitor = Process.monitor(queue)

    Process.exit(repo, :kill)

    assert_receive {:DOWN, ^monitor, :process, ^queue, :normal}, @await_ms
    :ok = WriterQueue.release(slot)
    # A synchronous call to the registry processes its DOWN for the queue
    # first, so the stopped queue is no longer handed out.
    assert {:ok, new_queue} = WriterQueue.Registry.start_queue(key)
    refute new_queue == queue
  end

  defp deadline(ms), do: System.monotonic_time(:millisecond) + ms

  defp start_waiter(key, label, max_waiters \\ @max_waiters) do
    parent = self()

    # Not linked: some tests kill a waiter.
    spawn(fn ->
      case WriterQueue.acquire(key, deadline(@await_ms), max_waiters) do
        {:ok, slot} ->
          send(parent, {:granted, label, self()})

          receive do
            :release -> WriterQueue.release(slot)
          after
            @await_ms * 2 -> :ok
          end

        {:error, reason} ->
          send(parent, {:refused, label, reason})
      end
    end)
  end

  defp await_waiting(key, count, deadline \\ nil) do
    deadline = deadline || deadline(@await_ms)

    cond do
      WriterQueue.waiting(key) == count ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("expected #{count} waiting writers, found #{WriterQueue.waiting(key)}")

      true ->
        Process.sleep(1)
        await_waiting(key, count, deadline)
    end
  end
end
