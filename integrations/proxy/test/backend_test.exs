defmodule Snodo.Proxy.BackendTest do
  use ExUnit.Case, async: true

  alias Snodo.Client
  alias Snodo.Client.Subscription
  alias Snodo.Proxy.Backend

  setup do
    fixture = Path.expand("../fixtures/stdio_logging_backend.exs", __DIR__)
    snodo_ebin = Path.expand("../../snodo/ebin", Mix.Project.compile_path())

    backend =
      start_supervised!(
        {Backend,
         id: "stdio",
         prefix: "stdio",
         manager: self(),
         target: {:stdio, System.find_executable("elixir"), ["-pa", snodo_ebin, fixture]},
         client_options: [on_log: self()],
         health_interval_ms: 60_000,
         queue_timeout_ms: 20}
      )

    assert_receive {:backend_ready, "stdio", ^backend, snapshot}, 5_000
    %{backend: backend, client: snapshot.client}
  end

  test "a busy health probe preserves the active call and retries", context do
    %{backend: backend, client: client} = context
    {call, socket} = held_call(client)
    original = :sys.get_state(backend)

    # The next successful probe must come from the retry scheduled by the busy probe.
    :sys.replace_state(backend, &%{&1 | health_interval_ms: 20})
    send(backend, :health_check)
    assert :sys.get_state(backend).catalog == original.catalog
    assert Process.alive?(backend)
    refute_received {:backend_error, _, _, _}
    assert Task.yield(call, 0) == nil

    :sys.replace_state(backend, &%{&1 | health_interval_ms: 60_000})
    release_call(call, socket)
    assert_receive {:backend_catalog, "stdio", ^backend, snapshot, nil}, 1_000
    assert snapshot.catalog == original.catalog
    assert :sys.get_state(backend).catalog == original.catalog
    assert Process.alive?(backend)
    refute_received {:backend_error, _, _, _}
  end

  test "a busy background refresh keeps the snapshot without reporting an error", context do
    %{backend: backend, client: client} = context
    {call, socket} = held_call(client)
    ref = make_ref()

    state = %{
      :sys.get_state(backend)
      | listener: %Subscription{ref: ref, id: "test", accepted: %{}, owner: self(), pid: self()}
    }

    assert {:noreply, ^state} =
             Backend.handle_info({:snodo_subscription, ref, {:dropped, 1}}, state)

    refute_received {:backend_error, _, _, _}
    refute_received {:backend_catalog, _, _, _, _}
    release_call(call, socket)

    assert {:noreply, refreshed} =
             Backend.handle_info({:snodo_subscription, ref, {:dropped, 1}}, state)

    assert refreshed.catalog == state.catalog
    assert_receive {:backend_catalog, "stdio", _, _, nil}
  end

  test "a closed connection still fails its health probe", %{backend: backend, client: client} do
    monitor = Process.monitor(backend)
    :ok = Client.close(client)
    send(backend, :health_check)
    assert_receive {:backend_error, "stdio", ^backend, _error}
    assert_receive {:DOWN, ^monitor, :process, ^backend, :normal}
  end

  defp held_call(client) do
    {:ok, barrier} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_tcp.close(barrier) end)
    {:ok, port} = :inet.port(barrier)

    call =
      Task.async(fn ->
        Backend.request(client, fn ->
          Client.call_tool(client, "log", %{"port" => port, "name" => "held", "level" => "error"},
            log_level: :error
          )
        end)
      end)

    assert {:ok, socket} = :gen_tcp.accept(barrier, 5_000)
    assert {:ok, "held"} = :gen_tcp.recv(socket, 4, 1_000)
    {call, socket}
  end

  defp release_call(call, socket) do
    :ok = :gen_tcp.send(socket, "release")
    :ok = :gen_tcp.close(socket)
    assert {:ok, %{"content" => [%{"text" => "held"}]}} = Task.await(call, 5_000)
    assert_received {:snodo_log, %{"level" => "error", "data" => "held"}}
  end
end
