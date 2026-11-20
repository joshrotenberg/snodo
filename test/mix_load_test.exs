defmodule Snodo.MixLoadTest do
  # The task swaps the global Mix shell.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Snodo.Load, as: LoadTask
  alias Snodo.Server.Executor

  @small [
    requests: 30,
    concurrency: 30,
    delay_ms: 2,
    max_concurrency: 4,
    sample_ms: 2,
    client_timeout: 10_000,
    warmup: false
  ]

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)
  end

  test "held handlers fill the executor and every request beyond it is rejected" do
    # 2 running and 3 queued are held; the other 7 can only be rejected, and
    # the gate releases the held handlers once those 7 are answered.
    gate = start_gate(release_after: 7)

    opts =
      Keyword.merge(@small, requests: 12, concurrency: 12, max_concurrency: 2, max_queue: 3)

    report = Snodo.Load.run(Keyword.put(opts, :gate, gate))

    for name <- ["stdio", "http"] do
      assert_receive {:gate_full, %{running: 2, queued: 3}, 2}
      assert %{transports: [t]} = Enum.find(report.scenarios, &(&1.name == name))

      assert %{configured: 12, attempted: 12, answered: 12, completed: 5, rejected: 7} = t
      assert %{error_responses: 0, unanswered: 0, unsent: 0} = t
      assert t.errors == %{"-32603 Server execution capacity exhausted" => 7}
      assert t.to_start.count == 5
      assert t.rejection_latency.count == 7
    end
  end

  test "a queue that holds every request rejects none and reports queue wait" do
    report = Snodo.Load.run(Keyword.merge(@small, max_queue: 30, delay_ms: 5))

    for %{transports: [t]} = scenario <- report.scenarios do
      assert %{configured: 30, answered: 30, completed: 30, rejected: 0} = t
      assert %{unanswered: 0, unsent: 0} = t
      assert t.execution.count == 30
      # 30 requests on 4 slots: some request waited for a slot to free.
      assert t.to_start.max >= 5
      assert t.to_start.max <= t.end_to_end.max
      assert scenario.executor.sampled_max_running <= 4
    end
  end

  test "shared mode releases each transport's traffic after setup, staggered" do
    opts =
      Keyword.merge(@small,
        max_queue: 60,
        shared: true,
        http_requests: 5,
        stagger_ms: 30
      )

    assert %{scenarios: [%{name: "shared", transports: [stdio, http]}]} = Snodo.Load.run(opts)
    assert %{transport: "stdio", completed: 30, unanswered: 0} = stdio
    assert %{transport: "http", completed: 5, unanswered: 0} = http
    assert stdio.first_send_ms < 30
    assert http.first_send_ms >= 30
  end

  test "requests with no reply are unanswered, cleanup is bounded, and nothing leaks" do
    gate = start_gate(release_after: :never)

    opts =
      Keyword.merge(@small,
        requests: 4,
        concurrency: 2,
        max_concurrency: 1,
        client_timeout: 150,
        gate: gate
      )

    report = Snodo.Load.run(opts)

    for %{transports: [t]} <- report.scenarios do
      assert %{configured: 4, attempted: 4, answered: 0, unanswered: 4, unsent: 0} = t
      assert t.unanswered_latency.count == 4
      assert t.unanswered_latency.p50 >= 150
    end

    assert [%{reasons: %{"no response within 150 ms" => 4}}] =
             Enum.find(report.scenarios, &(&1.name == "stdio")).transports

    assert [%{reasons: reasons}] = Enum.find(report.scenarios, &(&1.name == "http")).transports
    assert [{"-32001 " <> _client_timeout, 4}] = Map.to_list(reasons)

    refute_received {:snodo_load_line, _ref, _at, _line}

    # A run right after is unaffected by the abandoned one.
    assert %{scenarios: [%{transports: [t]}]} =
             Snodo.Load.run(Keyword.merge(@small, max_queue: 30, transports: [:stdio]))

    assert %{configured: 30, completed: 30, unanswered: 0} = t
  end

  @tag capture_log: true
  test "requests left when the stdio server exits are unsent" do
    gate = start_gate(release_after: :never, kill_stdio_server: true)

    opts =
      Keyword.merge(@small,
        requests: 6,
        concurrency: 2,
        max_concurrency: 1,
        transports: [:stdio],
        gate: gate
      )

    assert %{scenarios: [%{transports: [t]}]} = Snodo.Load.run(opts)
    # Two lines were in flight when the server died, and nothing answered them.
    assert %{configured: 6, attempted: 2, answered: 0, unanswered: 2, unsent: 4} = t
    assert [{"stdio server exited: :killed", 6}] = Map.to_list(t.reasons)
  end

  @tag capture_log: true
  test "a listener that does not start is an error, reported for the warm-up too" do
    opts = Keyword.merge(@small, transports: [:http], listener_options: [path: "mcp"])

    assert_raise Snodo.Load.Error, ~r/HTTP listener did not start/, fn ->
      Snodo.Load.run(opts)
    end

    assert_raise Snodo.Load.Error, ~r/warm-up over http failed: the HTTP listener/, fn ->
      Snodo.Load.run(Keyword.put(opts, :warmup, true))
    end
  end

  test "the Mix task parses flags and prints a report or JSON" do
    args = ~w(--requests 10 --concurrency 10 --delay-ms 1 --max-concurrency 2 --max-queue 10
              --transport stdio --no-warmup)

    LoadTask.run(args)
    assert_received {:mix_shell, :info, ["snodo.load: 10 requests" <> _]}

    assert_received {:mix_shell, :info,
                     ["  stdio: 10 configured, 10 attempted, 10 answered (10 completed" <> _]}

    LoadTask.run(args ++ ["--json"])
    assert_received {:mix_shell, :info, ["{" <> _ = json]}
    assert %{"scenarios" => [%{"transports" => [%{"completed" => 10}]}]} = JSON.decode!(json)
  end

  test "the Mix task fails on unanswered requests unless allowed" do
    args = ~w(--requests 1 --concurrency 1 --delay-ms 300 --client-timeout 50
              --transport stdio --no-warmup)

    assert_raise Mix.Error, ~r/1 requests unanswered and 0 unsent/, fn -> LoadTask.run(args) end
    assert %{scenarios: [_]} = LoadTask.run(args ++ ["--allow-unanswered"])
  end

  test "the Mix task names the flag it refuses" do
    assert_raise Mix.Error, ~r/not understood: --bogus/, fn -> LoadTask.run(["--bogus"]) end
    assert_raise Mix.Error, ~r/--transport must be/, fn -> LoadTask.run(~w(--transport ws)) end
    assert_raise Mix.Error, ~r/--requests must be/, fn -> LoadTask.run(~w(--requests 0)) end

    assert_raise Mix.Error, ~r/--client-timeout must be an integer from 1 to 4294967295/, fn ->
      LoadTask.run(~w(--client-timeout 5000000000))
    end

    assert_raise Mix.Error, ~r/--backlog must be/, fn -> LoadTask.run(~w(--backlog 70000)) end
  end

  # Holds every handler that starts. With `release_after: n`, once n requests
  # have an outcome it reports the executor's counters and the number held to
  # the test, then releases them and any later ones. The count restarts with
  # each scenario's executor.
  defp start_gate(opts) do
    test = self()
    spawn_link(fn -> gate(test, Map.new(opts), %{executor: nil, held: [], outcomes: 0}) end)
  end

  defp gate(test, opts, state) do
    receive do
      {:snodo_load_executor, executor} ->
        gate(test, opts, %{executor: executor, held: [], outcomes: 0})

      {:snodo_load_stdio_server, server} ->
        gate(test, opts, Map.put(state, :server, server))

      {:snodo_load_started, pid} ->
        if opts[:kill_stdio_server], do: Process.exit(state.server, :kill)

        if state.held == :released do
          send(pid, :snodo_load_release)
          gate(test, opts, state)
        else
          gate(test, opts, %{state | held: [pid | state.held]})
        end

      {:snodo_load_outcome, _transport, _outcome} ->
        state = %{state | outcomes: state.outcomes + 1}

        if state.outcomes == opts.release_after do
          send(test, {:gate_full, Executor.stats(state.executor), length(state.held)})
          Enum.each(state.held, &send(&1, :snodo_load_release))
          gate(test, opts, %{state | held: :released})
        else
          gate(test, opts, state)
        end
    end
  end
end
