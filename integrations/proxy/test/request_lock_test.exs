defmodule Snodo.Proxy.RequestLockTest do
  use ExUnit.Case, async: true

  alias Snodo.Client
  alias Snodo.Client.Stdio
  alias Snodo.Proxy.Backend
  alias Snodo.Proxy.RequestLock

  setup do
    connection = self()
    lock = start_supervised!({RequestLock, connection})
    %{connection: connection, lock: lock}
  end

  test "hands off immediately in FIFO order", %{connection: connection, lock: lock} do
    holder = hold(connection)
    first = enqueue(lock)
    second = enqueue(lock)
    assert :queue.len(:sys.get_state(lock).queue) == 2

    send(holder.pid, :release)
    assert :ok = Task.await(holder)
    assert_receive {^first, {:ok, first_ref}}, 200
    refute_received {^second, _reply}

    newcomer = enqueue(lock)
    assert :queue.len(:sys.get_state(lock).queue) == 2
    :ok = GenServer.call(lock, {:release, first_ref})
    assert_receive {^second, {:ok, second_ref}}, 200
    refute_received {^newcomer, _reply}

    :ok = GenServer.call(lock, {:release, second_ref})
    assert_receive {^newcomer, {:ok, last_ref}}, 200
    :ok = GenServer.call(lock, {:release, last_ref})
  end

  test "queue timeout returns a defined error without running the request", %{
    connection: connection,
    lock: lock
  } do
    holder = hold(connection)
    parent = self()

    assert {:error, %{code: -32_603, data: %{"reason" => "stdio_queue_timeout"}}} =
             RequestLock.run(connection, fn -> send(parent, :ran) end, 20)

    refute_received :ran
    assert :queue.is_empty(:sys.get_state(lock).queue)
    assert :sys.get_state(lock).waiters == %{}
    send(holder.pid, :release)
    Task.await(holder)
    assert :ok = RequestLock.run(connection, fn -> :ok end)
  end

  test "an exited holder grants the next waiter", %{connection: connection, lock: lock} do
    parent = self()

    holder =
      spawn(fn ->
        RequestLock.run(connection, fn ->
          send(parent, :held)
          receive do: (:exit -> exit(:shutdown))
        end)
      end)

    assert_receive :held
    next = enqueue(lock)
    assert :queue.len(:sys.get_state(lock).queue) == 1
    send(holder, :exit)
    assert_receive {^next, {:ok, ref}}, 200
    :ok = GenServer.call(lock, {:release, ref})
  end

  test "an exited waiter is removed while the holder is still running", %{
    connection: connection,
    lock: lock
  } do
    holder = hold(connection)
    waiter = spawn(fn -> receive do: (:stop -> :ok) end)
    send(lock, {:"$gen_call", {waiter, make_ref()}, {:acquire, 30_000}})
    next = enqueue(lock)
    assert :queue.len(:sys.get_state(lock).queue) == 2
    send(waiter, :stop)
    await_waiters(lock, 1, System.monotonic_time(:millisecond) + 1_000)
    send(holder.pid, :release)
    Task.await(holder)
    assert_receive {^next, {:ok, ref}}, 200
    :ok = GenServer.call(lock, {:release, ref})
  end

  test "exceptions release the lock", %{connection: connection} do
    assert_raise RuntimeError, "failed", fn ->
      RequestLock.run(connection, fn -> raise "failed" end)
    end

    assert :ok = RequestLock.run(connection, fn -> :ok end)
  end

  test "connection termination releases waiting callers" do
    connection = spawn(fn -> receive do: (:stop -> :ok) end)
    lock = start_supervised!({RequestLock, connection}, id: :closing_lock)
    holder = hold(connection)

    caller =
      Task.async(fn -> RequestLock.run(connection, fn -> flunk("closed connection") end) end)

    await_waiters(lock, 1, System.monotonic_time(:millisecond) + 1_000)
    ref = Process.monitor(lock)
    send(connection, :stop)
    assert_receive {:DOWN, ^ref, :process, ^lock, :normal}
    assert {:error, %{data: %{"reason" => "backend_unavailable"}}} = Task.await(caller)
    send(holder.pid, :release)
    assert :ok = Task.await(holder)
  end

  test "other backend transports do not acquire a stdio lock" do
    assert :ok =
             Backend.request(
               %Client{
                 transport: {Client.Direct, nil},
                 protocol: "2026-07-28",
                 dialect: Snodo.Protocol.V2026_07_28
               },
               fn -> :ok end
             )
  end

  test "stdio requests execute in the caller process", %{connection: connection} do
    caller = self()

    client = %Client{
      transport: {Stdio, connection},
      protocol: "2026-07-28",
      dialect: Snodo.Protocol.V2026_07_28
    }

    assert ^caller = Backend.request(client, fn -> self() end)
  end

  defp hold(connection) do
    parent = self()

    task =
      Task.async(fn ->
        RequestLock.run(connection, fn ->
          send(parent, :held)
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive :held
    task
  end

  defp enqueue(lock) do
    tag = make_ref()
    send(lock, {:"$gen_call", {self(), tag}, {:acquire, 30_000}})
    tag
  end

  defp await_waiters(lock, count, deadline) do
    state = :sys.get_state(lock)

    if map_size(state.waiters) != count do
      assert System.monotonic_time(:millisecond) < deadline
      await_waiters(lock, count, deadline)
    end
  end
end
