defmodule Snodo.SessionManagerTest do
  use ExUnit.Case, async: true

  alias Snodo.Protocol.{V2025_11_25, V2026_07_28}
  alias Snodo.Session
  alias Snodo.Session.Manager
  alias SnodoTest.TestFixtures

  # A registry backed by the local one that reports each call to the test.
  defmodule Recording do
    @moduledoc false
    @behaviour Snodo.Session.Registry

    alias Snodo.Session.Registry.Local

    @impl true
    def child_spec({name, _owner}), do: Local.child_spec(name)

    @impl true
    def register({name, owner}, id, pid) do
      send(owner, {:registered, id, pid})
      Local.register(name, id, pid)
    end

    @impl true
    def lookup({name, _owner}, id), do: Local.lookup(name, id)

    @impl true
    def unregister({name, owner}, id) do
      send(owner, {:unregistered, id})
      Local.unregister(name, id)
    end
  end

  defp runtime, do: TestFixtures.runtime(protocols: [V2026_07_28, V2025_11_25])

  test "invalid options are refused when the manager starts" do
    assert_raise ArgumentError, ~r/:max_sessions/, fn -> Manager.start_link(max_sessions: 0) end
    assert_raise ArgumentError, ~r/:idle_timeout/, fn -> Manager.start_link(idle_timeout: -1) end
    assert_raise ArgumentError, ~r/:principal/, fn -> Manager.start_link(principal: :nope) end

    assert_raise ArgumentError, ~r/:registry/, fn -> Manager.start_link(registry: Enum) end
  end

  test "a session is registered under its ID, admitted by principal, and unregistered" do
    name = :"recording_#{System.unique_integer([:positive])}"
    manager = start_supervised!({Manager, registry: {Recording, {name, self()}}})
    config = Manager.config(manager)

    assert {:ok, %Session{id: id, pid: pid}} =
             Manager.start_session(config, runtime(), %{principal: "alice", client_id: "app"})

    assert_receive {:registered, ^id, ^pid}

    # A refreshed token for the same subject and client keeps the session.
    assert {:ok, %Session{id: ^id}} =
             Manager.admit(config, id, %{principal: "alice", client_id: "app", scopes: ["x"]})

    assert :error = Manager.admit(config, id, %{principal: "bob", client_id: "app"})
    assert :error = Manager.admit(config, "missing", %{principal: "alice", client_id: "app"})

    :ok = Session.close(pid)
    assert_receive {:unregistered, ^id}
    assert :error = Manager.admit(config, id, %{principal: "alice", client_id: "app"})
  end

  test "a custom principal function decides what a session is bound to" do
    manager = start_supervised!({Manager, principal: fn auth -> auth[:tenant] end})
    config = Manager.config(manager)

    assert {:ok, %Session{id: id}} = Manager.start_session(config, runtime(), %{tenant: "t1"})
    assert {:ok, _session} = Manager.admit(config, id, %{tenant: "t1", user: "other"})
    assert :error = Manager.admit(config, id, %{tenant: "t2"})
  end

  test "the default principal uses the snodo_oauth fields, or the whole auth value" do
    assert Manager.default_principal(%{principal: "p", client_id: "c", claims: %{}}) == {"p", "c"}
    assert Manager.default_principal(nil) == nil
    assert Manager.default_principal(%{"sub" => "p"}) == %{"sub" => "p"}
  end

  test "a session subscribes to at most 1,000 resources" do
    config = Manager.config(start_supervised!(Manager))
    assert {:ok, %Session{pid: pid}} = Manager.start_session(config, runtime(), nil)
    :ok = Session.ready(pid, "2025-11-25", nil, %{}, nil)

    context = %Snodo.Context{
      protocol_version: "2025-11-25",
      protocol: V2025_11_25,
      transport: %Snodo.Transport.Context{}
    }

    for index <- 1..1_000, do: :ok = Session.subscribe(pid, "test://r/#{index}", context)

    # A URI already subscribed is not counted again.
    assert :ok = Session.subscribe(pid, "test://r/1", context)

    assert {:error, %Snodo.Error{code: -32_602}} =
             Session.subscribe(pid, "test://r/1001", context)

    :ok = Session.unsubscribe(pid, "test://r/1")
    assert :ok = Session.subscribe(pid, "test://r/1001", context)
  end

  test "a session ends with the process that started it until it is ready" do
    config = Manager.config(start_supervised!(Manager))
    test = self()

    start = fn ready? ->
      spawn(fn ->
        {:ok, %Session{pid: pid}} = Manager.start_session(config, runtime(), nil)
        if ready?, do: :ok = Session.ready(pid, "2025-11-25", nil, %{}, nil)
        send(test, {:started, pid})
      end)

      assert_receive {:started, pid}
      pid
    end

    unready = start.(false)
    monitor = Process.monitor(unready)
    assert_receive {:DOWN, ^monitor, :process, ^unready, _reason}

    ready = start.(true)
    assert {:ok, %Session{ready?: true}} = Session.admit(ready, nil)
  end

  test "max_sessions bounds the sessions a manager starts" do
    config = Manager.config(start_supervised!({Manager, max_sessions: 1}))
    assert {:ok, %Session{pid: pid}} = Manager.start_session(config, runtime(), nil)
    assert {:error, :limit} = Manager.start_session(config, runtime(), nil)
    assert Manager.count(config) == 1

    :ok = Session.close(pid)
    assert {:ok, _session} = Manager.start_session(config, runtime(), nil)
  end
end
