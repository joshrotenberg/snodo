defmodule Snodo.Instrumentation.TelemetryTest do
  # :telemetry handlers are global, so the tests run one at a time.
  use ExUnit.Case, async: false

  alias Snodo.Extensions.Tasks.Runner
  alias Snodo.Extensions.Tasks.Store.Memory
  alias Snodo.Instrumentation
  alias Snodo.Instrumentation.Telemetry
  alias Snodo.Subscription
  alias Snodo.Subscription.Hub
  alias SnodoTest.Telemetry.Server
  alias SnodoTest.Telemetry.Tasks, as: TasksFixtures

  @dispatch [:snodo, :server, :dispatch]
  @job [:snodo, :tasks, :runner, :job]
  @transition [:snodo, :tasks, :store, :transition]

  # Every event in the catalog of guides/instrumentation.md.
  @events [
    @dispatch ++ [:start],
    @dispatch ++ [:stop],
    @dispatch ++ [:exception],
    [:snodo, :subscription, :open],
    [:snodo, :subscription, :publish],
    [:snodo, :subscription, :overflow],
    [:snodo, :subscription, :complete],
    [:snodo, :subscription, :close],
    @job ++ [:start],
    @job ++ [:stop],
    @transition
  ]

  setup do
    handler_id = {__MODULE__, make_ref()}
    :ok = :telemetry.attach_many(handler_id, @events, &__MODULE__.forward/4, self())
    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  def forward(event_name, measurements, metadata, owner) do
    send(owner, {:telemetry, event_name, measurements, metadata})
  end

  test "dispatch start and stop share one span context and no request params" do
    {:ok, hub} = start_supervised({Hub, instrumentation: Telemetry})

    runtime =
      Server.runtime(instrumentation: Telemetry, subscription_source: Hub.source(hub))

    assert {:ok, %{"result" => %{"tools" => [_echo]}}} =
             Snodo.Test.dispatch(runtime,
               id: "observed-dispatch",
               protocol: "2026-07-28",
               method: "tools/list",
               params: %{"secret" => "must-not-appear"}
             )

    assert_receive {:telemetry, [:snodo, :server, :dispatch, :start], %{system_time: system_time},
                    start_metadata},
                   1_000

    assert is_integer(system_time)

    assert %{
             method: "tools/list",
             request_id: "observed-dispatch",
             transport: :direct,
             telemetry_span_context: context
           } = start_metadata

    assert map_size(start_metadata) == 4
    assert is_reference(context)

    assert_receive {:telemetry, [:snodo, :server, :dispatch, :stop], %{duration: duration},
                    stop_metadata},
                   1_000

    assert is_integer(duration) and duration >= 0
    assert stop_metadata == Map.put(start_metadata, :outcome, :ok)
    refute inspect([start_metadata, stop_metadata]) =~ "must-not-appear"
  end

  test "error and stream outcomes keep the start context" do
    {:ok, hub} = start_supervised({Hub, instrumentation: Telemetry})

    runtime =
      Server.runtime(instrumentation: Telemetry, subscription_source: Hub.source(hub))

    assert {:ok, %{"error" => %{"code" => -32_601}}} =
             Snodo.Test.dispatch(runtime,
               id: "missing",
               protocol: "2026-07-28",
               method: "unknown/method"
             )

    assert_receive {:telemetry, [:snodo, :server, :dispatch, :start], _measurements,
                    %{request_id: "missing", telemetry_span_context: context}},
                   1_000

    assert_receive {:telemetry, [:snodo, :server, :dispatch, :stop], _measurements,
                    %{
                      request_id: "missing",
                      outcome: :error,
                      error_code: -32_601,
                      telemetry_span_context: ^context
                    }},
                   1_000

    assert {:stream, subscription} =
             Snodo.Test.dispatch(runtime,
               id: "observed-stream",
               protocol: "2026-07-28",
               method: "subscriptions/listen",
               params: %{"notifications" => %{"toolsListChanged" => true}}
             )

    assert_receive {:telemetry, [:snodo, :server, :dispatch, :start], _measurements,
                    %{request_id: "observed-stream", telemetry_span_context: stream_context}},
                   1_000

    assert_receive {:telemetry, [:snodo, :server, :dispatch, :stop], _measurements,
                    %{outcome: :stream, telemetry_span_context: ^stream_context}},
                   1_000

    refute stream_context == context
    assert :ok = Subscription.close(subscription, :cancelled)
  end

  test "an exception carries the start context and the bounded reason" do
    config = Instrumentation.normalize!(Telemetry)
    metadata = %{method: "tools/call", request_id: "raising", transport: :direct}

    assert_raise RuntimeError, "operation failure", fn ->
      Instrumentation.span(
        config,
        @dispatch,
        metadata,
        fn -> raise "operation failure" end,
        fn _ ->
          %{}
        end
      )
    end

    assert_receive {:telemetry, [:snodo, :server, :dispatch, :start], %{system_time: _},
                    %{request_id: "raising", telemetry_span_context: context}},
                   1_000

    assert_receive {:telemetry, [:snodo, :server, :dispatch, :exception], %{duration: duration},
                    exception_metadata},
                   1_000

    assert duration >= 0

    assert exception_metadata ==
             Map.merge(metadata, %{
               kind: :error,
               reason_class: RuntimeError,
               telemetry_span_context: context
             })
  end

  test "nested spans in one process get distinct contexts" do
    config = Instrumentation.normalize!(Telemetry)
    finish = fn _result -> %{outcome: :ok} end

    outer = fn ->
      Instrumentation.span(config, @dispatch, %{request_id: "inner"}, fn -> :inner end, finish)
    end

    assert :inner = Instrumentation.span(config, @dispatch, %{request_id: "outer"}, outer, finish)

    assert_receive {:telemetry, [:snodo, :server, :dispatch, :start], _,
                    %{request_id: "outer", telemetry_span_context: outer_context}},
                   1_000

    assert_receive {:telemetry, [:snodo, :server, :dispatch, :start], _,
                    %{request_id: "inner", telemetry_span_context: inner_context}},
                   1_000

    assert_receive {:telemetry, [:snodo, :server, :dispatch, :stop], _,
                    %{request_id: "inner", telemetry_span_context: ^inner_context}},
                   1_000

    assert_receive {:telemetry, [:snodo, :server, :dispatch, :stop], _,
                    %{request_id: "outer", telemetry_span_context: ^outer_context}},
                   1_000

    refute outer_context == inner_context
    refute Enum.any?(Process.get_keys(), &match?({Telemetry, _prefix}, &1))
  end

  test "a stop without a recorded start gets a fresh context" do
    config = Instrumentation.normalize!(Telemetry)

    :ok = Instrumentation.emit(config, @dispatch ++ [:stop], %{duration: 1}, %{outcome: :ok})

    assert_receive {:telemetry, [:snodo, :server, :dispatch, :stop], %{duration: 1},
                    %{outcome: :ok, telemetry_span_context: context}},
                   1_000

    assert is_reference(context)
  end

  test "subscription events are forwarded unchanged" do
    {:ok, hub} = start_supervised({Hub, max_buffer: 1, instrumentation: Telemetry})

    runtime =
      Server.runtime(instrumentation: Telemetry, subscription_source: Hub.source(hub))

    assert {:stream, subscription} =
             Snodo.Test.dispatch(runtime,
               id: "observed-sub",
               protocol: "2026-07-28",
               method: "subscriptions/listen",
               params: %{"notifications" => %{"toolsListChanged" => true}}
             )

    assert_receive {:telemetry, [:snodo, :subscription, :open], %{subscriptions: 1},
                    %{
                      request_id: "observed-sub",
                      transport: :direct,
                      filter_keys: ["toolsListChanged"]
                    } = open_metadata},
                   1_000

    assert map_size(open_metadata) == 3

    assert {:ok, %{dropped: 0}} = Hub.notify_tools_list_changed(hub)

    assert_receive {:telemetry, [:snodo, :subscription, :publish],
                    %{matched: 1, delivered: 0, buffered: 1, dropped: 0, queued: 1},
                    %{event_kind: :tools_list_changed} = publish_metadata},
                   1_000

    assert map_size(publish_metadata) == 1

    assert {:ok, %{dropped: 1}} = Hub.notify_tools_list_changed(hub)

    assert_receive {:telemetry, [:snodo, :subscription, :publish],
                    %{matched: 1, dropped: 1, queued: 1}, %{event_kind: :tools_list_changed}},
                   1_000

    assert_receive {:telemetry, [:snodo, :subscription, :overflow], %{dropped: 1, queued: 1},
                    %{event_kind: :tools_list_changed, policy: :drop_oldest}},
                   1_000

    :ok = Hub.complete(hub)

    assert_receive {:telemetry, [:snodo, :subscription, :complete],
                    %{subscriptions: 1, queued: 1}, %{}},
                   1_000

    :ok = Subscription.close(subscription, :complete)

    assert_receive {:telemetry, [:snodo, :subscription, :close], %{subscriptions: 0},
                    %{reason: :complete}},
                   1_000
  end

  test "runner job events share one context and the store transition is forwarded" do
    store = start_supervised!({Memory, scope: :shared})
    runner = start_supervised!({Runner, store: {Memory, store}, instrumentation: Telemetry})
    runtime = TasksFixtures.runtime(store, runner, Telemetry)

    assert {:ok, %{"result" => %{"taskId" => task_id}}} =
             Snodo.Test.dispatch(runtime,
               id: "observed-task",
               protocol: "2026-07-28",
               client_capabilities: TasksFixtures.client_capabilities(),
               method: "tools/call",
               params: %{"name" => "echo", "arguments" => %{"text" => "private input"}}
             )

    assert_receive {:telemetry, [:snodo, :tasks, :runner, :job, :start],
                    %{jobs: 1, system_time: system_time},
                    %{
                      task_id: ^task_id,
                      revision: 0,
                      source: :request,
                      telemetry_span_context: context
                    } = start_metadata},
                   1_000

    assert is_integer(system_time)
    assert map_size(start_metadata) == 4

    assert_receive {:telemetry, [:snodo, :tasks, :store, :transition], %{duration: duration},
                    %{
                      task_id: ^task_id,
                      expected_revision: 0,
                      event_kind: :completed,
                      authority: :worker,
                      outcome: :applied
                    } = transition_metadata},
                   1_000

    assert duration >= 0
    assert map_size(transition_metadata) == 5

    assert_receive {:telemetry, [:snodo, :tasks, :runner, :job, :stop],
                    %{duration: job_duration, jobs: 0},
                    %{
                      task_id: ^task_id,
                      outcome: :completed,
                      store_outcome: :applied,
                      release_outcome: :ok,
                      telemetry_span_context: ^context
                    } = stop_metadata},
                   1_000

    assert job_duration >= duration
    assert map_size(stop_metadata) == 5
    refute inspect([start_metadata, transition_metadata, stop_metadata]) =~ "private input"
  end

  test "interleaved job spans are keyed by task" do
    config = Instrumentation.normalize!(Telemetry)
    start = %{jobs: 2, system_time: System.system_time()}
    stop = %{duration: 1, jobs: 1}

    :ok = Instrumentation.emit(config, @job ++ [:start], start, %{task_id: "a", revision: 0})
    :ok = Instrumentation.emit(config, @job ++ [:start], start, %{task_id: "b", revision: 0})

    :ok =
      Instrumentation.emit(config, @job ++ [:stop], stop, %{task_id: "a", outcome: :completed})

    :ok =
      Instrumentation.emit(config, @job ++ [:stop], stop, %{task_id: "b", outcome: :completed})

    assert_receive {:telemetry, [:snodo, :tasks, :runner, :job, :start], _,
                    %{task_id: "a", telemetry_span_context: a}},
                   1_000

    assert_receive {:telemetry, [:snodo, :tasks, :runner, :job, :start], _,
                    %{task_id: "b", telemetry_span_context: b}},
                   1_000

    assert_receive {:telemetry, [:snodo, :tasks, :runner, :job, :stop], _,
                    %{task_id: "a", telemetry_span_context: ^a}},
                   1_000

    assert_receive {:telemetry, [:snodo, :tasks, :runner, :job, :stop], _,
                    %{task_id: "b", telemetry_span_context: ^b}},
                   1_000

    refute a == b
    refute Enum.any?(Process.get_keys(), &match?({Telemetry, _prefix, _task}, &1))
  end
end
