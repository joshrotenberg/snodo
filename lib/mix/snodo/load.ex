defmodule Snodo.Load do
  @moduledoc false

  # Load run behind `mix snodo.load`. It drives `tools/call` requests through
  # the real stdio and native Streamable HTTP transports into an application
  # owned `Snodo.Server.Executor`, and measures what the executor does with
  # them. Like the rest of lib/mix outside snodo.catalog, it is left out of the
  # Hex package.
  #
  # Every configured request ends in exactly one outcome:
  #
  #   * answered: a result (`completed`), a capacity refusal (`rejected`), or
  #     any other JSON-RPC error the server returned (`error_response`);
  #   * unanswered: the peer gave up, after `client_timeout` with no reply or
  #     on a client transport error;
  #   * unsent: the peer never sent it, because the stdio server exited first.
  #
  # Latencies:
  #
  #   * to start: from the peer's send boundary to handler start, for
  #     completed requests only. The handler returns the monotonic time it
  #     started, comparable because the peers run in the same VM. On stdio the
  #     boundary is the moment the pre-encoded line is handed to the input
  #     device; on HTTP it is the call to `Snodo.Client.call_tool/4`, so it
  #     also covers client work, pool checkout, and connecting.
  #   * end to end, rejection, error response, unanswered: from the same
  #     boundary to the outcome.
  #   * execution: the `duration` of `[:snodo, :server, :dispatch, :stop]`,
  #     reported through an instrumentation sink. It runs inside the executor
  #     task, so it excludes queue wait.
  #
  # Queue depth comes from `Snodo.Server.Executor.stats/1`, sampled through the
  # executor's mailbox, so the reported values are sampled maxima: the true
  # peaks can be higher.
  #
  # Each driver is set up before any traffic is released, and its traffic runs
  # in a task of its own, so replies that arrive after the peer gives up die
  # with that task instead of reaching a later run.

  alias Snodo.Client
  alias Snodo.Protocol.V2026_07_28, as: Protocol
  alias Snodo.Server.Executor
  alias Snodo.Transport.Stdio
  alias Snodo.Transport.StreamableHTTP.Server, as: HTTPServer

  @rejection "Server execution capacity exhausted"
  # Erlang timers take at most 2^32 - 1 milliseconds.
  @max_timer 4_294_967_295
  # How long cleanup waits for a transport to finish before stopping it.
  @drain_ms 1_000

  @defaults [
    requests: 1_000,
    concurrency: 1_000,
    delay_ms: 10,
    max_concurrency: 32,
    max_queue: 256,
    request_timeout: 30_000,
    client_timeout: 60_000,
    sample_ms: 5,
    backlog: 1_024,
    warmup: true,
    transports: [:stdio, :http],
    stdio_requests: nil,
    http_requests: nil,
    shared: false,
    stagger_ms: 0,
    # Test hooks, not command-line flags.
    gate: nil,
    listener_options: []
  ]

  defmodule Error do
    @moduledoc false
    defexception [:message]
  end

  defmodule Tool do
    @moduledoc false

    use Snodo.Tool,
      name: "load",
      description: "Sleep for delayMs and return the monotonic time the handler started"

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "delayMs" => %{"type" => "integer", "minimum" => 0},
        "gate" => %{"type" => "string"}
      },
      "required" => ["delayMs"]
    })

    @impl true
    def call(%{"delayMs" => delay} = arguments, _context) do
      started = System.monotonic_time()
      hold(arguments["gate"], delay)
      {:ok, Snodo.Result.text(Integer.to_string(started))}
    end

    # A gate is a test process that decides when held handlers return, so a
    # test can keep running slots occupied while it checks the executor.
    defp hold(nil, delay), do: if(delay > 0, do: Process.sleep(delay))

    defp hold(token, _delay) do
      send(:persistent_term.get({__MODULE__, token}), {:snodo_load_started, self()})

      receive do
        :snodo_load_release -> :ok
      end
    end
  end

  defmodule Server do
    @moduledoc false

    use Snodo.Server,
      name: "snodo-load",
      version: "0.0.0",
      protocols: [Snodo.Protocol.V2026_07_28]

    tool(Snodo.Load.Tool)
  end

  defmodule Sink do
    @moduledoc false
    @behaviour Snodo.Instrumentation

    @impl true
    def handle_event([:snodo, :server, :dispatch, :stop], measurements, metadata, table) do
      :ets.insert(table, {metadata.transport, measurements.duration, metadata.outcome})
    end

    def handle_event(_name, _measurements, _metadata, _table), do: :ok
  end

  defmodule Input do
    @moduledoc false

    # A line-oriented input device: `push/2` queues a line, `eof/1` ends input.

    def start_link, do: {:ok, spawn_link(fn -> loop(:queue.new(), nil, false) end)}
    def push(device, line), do: send(device, {:push, line})
    def eof(device), do: send(device, :eof)

    defp loop(queue, waiter, eof?) do
      receive do
        {:push, line} ->
          serve(:queue.in(line, queue), waiter, eof?)

        :eof ->
          serve(queue, waiter, true)

        {:io_request, from, reply_as, {:get_line, _encoding, _prompt}} ->
          serve(queue, {from, reply_as}, eof?)

        {:io_request, from, reply_as, _unsupported} ->
          send(from, {:io_reply, reply_as, {:error, :enotsup}})
          loop(queue, waiter, eof?)
      end
    end

    defp serve(queue, nil, eof?), do: loop(queue, nil, eof?)

    defp serve(queue, {from, reply_as} = waiter, eof?) do
      case :queue.out(queue) do
        {{:value, line}, rest} ->
          send(from, {:io_reply, reply_as, line})
          loop(rest, nil, eof?)

        {:empty, queue} when eof? ->
          send(from, {:io_reply, reply_as, :eof})
          loop(queue, nil, eof?)

        {:empty, queue} ->
          loop(queue, waiter, eof?)
      end
    end
  end

  defmodule Output do
    @moduledoc false

    # An output device that acknowledges each write at once and sends every
    # complete line to its owner as `{:snodo_load_line, ref, monotonic_time,
    # line}`. The owner is set with `{:owner, pid}` before traffic starts.

    def start_link(ref), do: {:ok, spawn_link(fn -> loop(ref, nil, "") end)}

    defp loop(ref, owner, buffer) do
      receive do
        {:owner, owner} ->
          loop(ref, owner, buffer)

        {:io_request, from, reply_as, request} ->
          at = System.monotonic_time()
          send(from, {:io_reply, reply_as, reply(request)})
          loop(ref, owner, emit(ref, owner, at, buffer <> chars(request)))
      end
    end

    defp reply({:put_chars, _encoding, _chars}), do: :ok
    defp reply({:put_chars, _chars}), do: :ok
    defp reply(_unsupported), do: {:error, :enotsup}

    defp chars({:put_chars, _encoding, chars}), do: IO.iodata_to_binary(chars)
    defp chars({:put_chars, chars}), do: IO.iodata_to_binary(chars)
    defp chars(_unsupported), do: ""

    defp emit(ref, owner, at, buffer) do
      {lines, [rest]} = buffer |> String.split("\n") |> Enum.split(-1)
      if owner, do: Enum.each(lines, &send(owner, {:snodo_load_line, ref, at, &1}))
      rest
    end
  end

  @doc false
  def defaults, do: @defaults

  @doc false
  # Runs the configured scenarios and returns a report map. Raises
  # ArgumentError for an invalid option and Snodo.Load.Error when a run
  # cannot be set up or the warm-up fails.
  def run(opts \\ []) do
    opts = Keyword.merge(@defaults, opts)
    validate!(opts)
    if opts[:warmup], do: warm_up(opts)

    scenarios =
      if opts[:shared] do
        [run_scenario("shared", opts[:transports], opts)]
      else
        Enum.map(opts[:transports], &run_scenario(Atom.to_string(&1), [&1], opts))
      end

    %{config: config(opts), system: system_info(), scenarios: scenarios}
  end

  defp config(opts) do
    opts |> Keyword.drop([:gate, :listener_options]) |> Map.new()
  end

  # Loads the transport, client, and executor code before anything is timed.
  # Every warm-up request should complete: the queue holds all of them.
  defp warm_up(opts) do
    opts =
      Keyword.merge(opts,
        requests: 20,
        stdio_requests: nil,
        http_requests: nil,
        concurrency: 20,
        max_queue: 20,
        delay_ms: 0,
        gate: nil
      )

    for transport <- opts[:transports] do
      %{transports: [summary]} =
        try do
          run_scenario("warm-up", [transport], opts)
        rescue
          error ->
            reraise Error,
                    [message: "warm-up over #{transport} failed: #{Exception.message(error)}"],
                    __STACKTRACE__
        end

      if summary.completed != summary.configured do
        raise Error,
              "warm-up over #{transport} completed #{summary.completed} of " <>
                "#{summary.configured} requests: #{inspect(outcome_counts(summary))}"
      end
    end

    :ok
  end

  defp outcome_counts(summary) do
    Map.take(summary, [:rejected, :error_responses, :unanswered, :unsent, :errors, :reasons])
  end

  # Sets up every driver, then releases their traffic together. A driver
  # after the first waits `stagger_ms` more than the one before it.
  defp run_scenario(name, transports, opts) do
    with_executor(opts, fn executor, sink, sampler ->
      with_drivers(transports, executor, sink, opts, [], fn drivers ->
        release(name, drivers, executor, sampler, opts)
      end)
    end)
  end

  defp release(name, drivers, executor, sampler, opts) do
    started = System.monotonic_time()

    results =
      drivers
      |> Enum.with_index()
      |> Enum.map(&Task.async(fn -> fire(&1, started, executor, opts) end))
      |> Task.await_many(:infinity)

    # Sampling stops with the traffic, before cleanup.
    {name, System.monotonic_time() - started, results, stop_sampler(sampler)}
  end

  defp with_executor(opts, fun) do
    table = :ets.new(:snodo_load_dispatch, [:duplicate_bag, :public, write_concurrency: true])

    try do
      # Unlinked, so an executor that dies is reported through the transports
      # instead of taking the run down.
      {:ok, executor} =
        GenServer.start(Executor,
          max_concurrency: opts[:max_concurrency],
          max_queue: opts[:max_queue],
          default_timeout: opts[:request_timeout]
        )

      try do
        if opts[:gate], do: send(opts[:gate], {:snodo_load_executor, executor})
        sampler = start_sampler(executor, opts[:sample_ms])

        try do
          {name, wall, results, samples} = fun.(executor, {Sink, table}, sampler)
          dispatches = :ets.tab2list(table)

          %{
            name: name,
            wall_ms: native_ms(wall),
            executor: Map.put(samples, :sample_ms, opts[:sample_ms]),
            transports: Enum.map(results, &summarize(&1, dispatches))
          }
        after
          stop_linked(sampler)
        end
      after
        stop_process(executor)
      end
    after
      :ets.delete(table)
    end
  end

  defp with_drivers([], _executor, _sink, _opts, drivers, fun), do: fun.(Enum.reverse(drivers))

  defp with_drivers([transport | rest], executor, sink, opts, drivers, fun) do
    driver = prepare(transport, executor, sink, opts)

    try do
      with_drivers(rest, executor, sink, opts, [driver | drivers], fun)
    after
      cleanup(driver)
    end
  end

  defp request_count(:stdio, opts), do: opts[:stdio_requests] || opts[:requests]
  defp request_count(:http, opts), do: opts[:http_requests] || opts[:requests]

  defp arguments(opts, token) do
    if token,
      do: %{"delayMs" => opts[:delay_ms], "gate" => token},
      else: %{"delayMs" => opts[:delay_ms]}
  end

  # A gate token lets the tool find the test's gate process.
  defp gate_token(opts) do
    case opts[:gate] do
      nil ->
        nil

      gate ->
        token = Integer.to_string(System.unique_integer([:positive]))
        :persistent_term.put({Tool, token}, gate)
        token
    end
  end

  defp drop_gate(nil), do: :ok
  defp drop_gate(token), do: :persistent_term.erase({Tool, token})

  ## Stdio driver

  defp prepare(:stdio, executor, sink, opts) do
    count = request_count(:stdio, opts)
    token = gate_token(opts)
    ref = make_ref()
    runtime = Server.runtime(instrumentation: sink)
    lines = encode_lines(count, arguments(opts, token))
    {:ok, input} = Input.start_link()
    {:ok, output} = Output.start_link(ref)
    {:ok, supervisor} = Task.Supervisor.start_link()

    # Not linked, so a serve task that dies ends the traffic as unanswered and
    # unsent requests instead of taking the run down.
    server =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Stdio.serve(runtime, input: input, output: output, executor: executor)
      end)

    if opts[:gate], do: send(opts[:gate], {:snodo_load_stdio_server, server.pid})

    %{
      supervisor: supervisor,
      transport: :stdio,
      count: count,
      token: token,
      ref: ref,
      lines: lines,
      input: input,
      output: output,
      server: server
    }
  end

  defp prepare(:http, executor, sink, opts) do
    count = request_count(:http, opts)
    token = gate_token(opts)

    listener_options =
      Keyword.merge(
        [
          runtime: Server.runtime(instrumentation: sink),
          port: 0,
          executor: executor,
          request_timeout: opts[:request_timeout],
          backlog: opts[:backlog],
          drain_timeout: @drain_ms
        ],
        opts[:listener_options]
      )

    # Unlinked, so a listener that fails to start returns an error here.
    listener =
      case GenServer.start(HTTPServer, listener_options) do
        {:ok, listener} ->
          listener

        {:error, reason} ->
          drop_gate(token)
          raise Error, "the HTTP listener did not start: #{inspect(reason, limit: 8)}"
      end

    client =
      case Client.connect({:http, HTTPServer.url(listener)},
             protocol: "2026-07-28",
             pool_size: opts[:concurrency],
             timeout: opts[:client_timeout]
           ) do
        {:ok, client} ->
          client

        {:error, error} ->
          stop_process(listener)
          drop_gate(token)
          raise Error, "the HTTP client did not connect: #{error.message}"
      end

    %{
      transport: :http,
      count: count,
      token: token,
      arguments: arguments(opts, token),
      listener: listener,
      client: client
    }
  end

  defp cleanup(%{transport: :stdio} = driver) do
    Input.eof(driver.input)
    _result = Task.yield(driver.server, @drain_ms) || stop_stdio(driver.server)
    stop_linked(driver.supervisor)
    stop_linked(driver.input)
    stop_linked(driver.output)
    drop_gate(driver.token)
  end

  defp cleanup(%{transport: :http} = driver) do
    Client.close(driver.client)
    stop_process(driver.listener)
    drop_gate(driver.token)
  end

  # `Stdio.serve/2` monitors the coordinator it starts. Stopping the
  # coordinator with :shutdown cancels its executor work and makes `serve/2`
  # return; killing the serve task is the last resort.
  defp stop_stdio(server) do
    {:monitors, monitors} = Process.info(server.pid, :monitors) || {:monitors, []}

    for {:process, pid} <- monitors, coordinator?(pid), do: stop_process(pid, :shutdown)

    Task.yield(server, @drain_ms) || Task.shutdown(server, :brutal_kill)
  end

  defp coordinator?(pid), do: match?({Stdio, :init, _args}, :proc_lib.initial_call(pid))

  defp encode_lines(count, arguments) do
    meta = Protocol.request_metadata(%{})

    for id <- 1..count//1 do
      JSON.encode!(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => "tools/call",
        "params" => %{"name" => "load", "arguments" => arguments, "_meta" => meta}
      }) <> "\n"
    end
    |> List.to_tuple()
  end

  # Each record is {outcome, sent_at, at, started_at | nil, detail | nil}.
  defp fire({driver, index}, started, executor, opts) do
    delay = index * opts[:stagger_ms]
    if delay > 0, do: Process.sleep(delay)
    first_send = System.monotonic_time()
    %{queued: queued, running: running} = stats(executor)
    records = drive(driver, opts)

    %{
      transport: driver.transport,
      records: records,
      first_send_ms: native_ms(first_send - started),
      at_first_send: %{queued: queued, running: running}
    }
  end

  defp stats(executor) do
    Executor.stats(executor)
  catch
    :exit, _reason -> %{queued: nil, running: nil}
  end

  defp drive(%{transport: :stdio} = driver, opts) do
    send(driver.output, {:owner, self()})
    server_monitor = Process.monitor(driver.server.pid)
    window = min(opts[:concurrency], driver.count)

    state = %{
      driver: driver,
      opts: opts,
      monitor: server_monitor,
      next: 1,
      sent: %{},
      deadlines: :queue.new(),
      records: []
    }

    state = Enum.reduce(1..window//1, state, fn _id, state -> send_next(state) end)
    collect(state)
  end

  defp drive(%{transport: :http} = driver, opts) do
    next = :atomics.new(1, [])

    1..min(opts[:concurrency], driver.count)//1
    |> Enum.map(fn _worker -> Task.async(fn -> http_worker(driver, next, opts, []) end) end)
    |> Task.await_many(:infinity)
    |> List.flatten()
  end

  defp send_next(%{next: next, driver: %{count: count}} = state) when next > count, do: state

  defp send_next(%{next: id, driver: driver} = state) do
    sent_at = System.monotonic_time()
    Input.push(driver.input, elem(driver.lines, id - 1))

    deadline =
      sent_at + System.convert_time_unit(state.opts[:client_timeout], :millisecond, :native)

    %{
      state
      | next: id + 1,
        sent: Map.put(state.sent, id, sent_at),
        deadlines: :queue.in({deadline, id}, state.deadlines)
    }
  end

  defp collect(%{sent: sent, next: next, driver: %{count: count}} = state)
       when map_size(sent) == 0 and next > count,
       do: finish(state)

  defp collect(state) do
    ref = state.driver.ref
    monitor = state.monitor

    receive do
      {:snodo_load_line, ^ref, at, line} ->
        state |> answer(JSON.decode!(line), at) |> collect()

      {:DOWN, ^monitor, :process, _pid, reason} ->
        give_up(state, "stdio server exited: #{inspect(reason, limit: 5)}")
    after
      wait_ms(state) ->
        state |> expire() |> collect()
    end
  end

  # A reply for a request the peer already gave up on is dropped.
  defp answer(state, %{"id" => id} = message, at) when is_map_key(state.sent, id) do
    {sent_at, sent} = Map.pop!(state.sent, id)
    record = stdio_record(message, sent_at, at)
    notify_gate(state.opts, :stdio, record)
    send_next(%{state | sent: sent, records: [record | state.records]})
  end

  defp answer(state, _message, _at), do: state

  defp wait_ms(state) do
    case next_deadline(state) do
      {nil, _state} ->
        :infinity

      {deadline, _state} ->
        remaining = deadline - System.monotonic_time()
        max(System.convert_time_unit(remaining, :native, :millisecond) + 1, 0)
    end
  end

  # Skips deadlines of requests already answered.
  defp next_deadline(state) do
    case :queue.peek(state.deadlines) do
      {:value, {deadline, id}} when is_map_key(state.sent, id) ->
        {deadline, state}

      {:value, _answered} ->
        next_deadline(%{state | deadlines: :queue.drop(state.deadlines)})

      :empty ->
        {nil, state}
    end
  end

  defp expire(state) do
    now = System.monotonic_time()
    {deadline, state} = next_deadline(state)

    if deadline != nil and deadline <= now do
      {{:value, {_deadline, id}}, deadlines} = :queue.out(state.deadlines)
      {sent_at, sent} = Map.pop!(state.sent, id)
      timeout = state.opts[:client_timeout]
      record = {:unanswered, sent_at, now, nil, "no response within #{timeout} ms"}
      notify_gate(state.opts, :stdio, record)

      %{state | sent: sent, deadlines: deadlines, records: [record | state.records]}
      |> send_next()
      |> expire()
    else
      state
    end
  end

  # The server is gone: what was sent is unanswered, the rest was never sent.
  defp give_up(state, reason) do
    now = System.monotonic_time()
    unanswered = for {_id, sent_at} <- state.sent, do: {:unanswered, sent_at, now, nil, reason}
    unsent = for _id <- state.next..state.driver.count//1, do: {:unsent, nil, nil, nil, reason}
    finish(%{state | sent: %{}, records: unanswered ++ unsent ++ state.records})
  end

  defp finish(state) do
    Process.demonitor(state.monitor, [:flush])
    state.records
  end

  defp stdio_record(%{"result" => %{"content" => [%{"text" => text} | _]}}, sent_at, at),
    do: {:completed, sent_at, at, String.to_integer(text), nil}

  defp stdio_record(%{"error" => %{"code" => code, "message" => message}}, sent_at, at),
    do: error_record(code, message, sent_at, at)

  defp stdio_record(other, sent_at, at),
    do: {:error_response, sent_at, at, nil, "unexpected " <> inspect(other, limit: 5)}

  defp http_worker(driver, next, opts, records) do
    if :atomics.add_get(next, 1, 1) > driver.count do
      records
    else
      sent_at = System.monotonic_time()
      response = call(driver)
      record = http_record(response, sent_at, System.monotonic_time())
      notify_gate(opts, :http, record)
      http_worker(driver, next, opts, [record | records])
    end
  end

  defp call(driver) do
    Client.call_tool(driver.client, "load", driver.arguments)
  rescue
    exception -> {:exception, Exception.message(exception)}
  catch
    kind, reason -> {:exception, "#{kind}: #{inspect(reason, limit: 5)}"}
  end

  defp http_record({:ok, %{"content" => [%{"text" => text} | _]}}, sent_at, at),
    do: {:completed, sent_at, at, String.to_integer(text), nil}

  # The client reports its own failures, including its request timeout, as
  # transport errors: the server's answer, if any, never arrived.
  defp http_record({:error, %Snodo.Error{kind: :transport} = error}, sent_at, at),
    do: {:unanswered, sent_at, at, nil, "#{error.code} #{error.message}"}

  defp http_record({:error, %Snodo.Error{code: code, message: message}}, sent_at, at),
    do: error_record(code, message, sent_at, at)

  defp http_record({:exception, message}, sent_at, at),
    do: {:unanswered, sent_at, at, nil, "client raised: " <> message}

  defp http_record(other, sent_at, at),
    do: {:error_response, sent_at, at, nil, "unexpected " <> inspect(other, limit: 5)}

  defp error_record(code, @rejection = message, sent_at, at),
    do: {:rejected, sent_at, at, nil, "#{code} #{message}"}

  defp error_record(code, message, sent_at, at),
    do: {:error_response, sent_at, at, nil, "#{code} #{message}"}

  defp notify_gate(opts, transport, record) do
    if opts[:gate], do: send(opts[:gate], {:snodo_load_outcome, transport, elem(record, 0)})
  end

  ## Report

  defp summarize(%{transport: transport, records: records} = result, dispatches) do
    by = Enum.group_by(records, &elem(&1, 0))
    take = &Map.get(by, &1, [])
    completed = take.(:completed)
    rejected = take.(:rejected)
    error_responses = take.(:error_response)
    unanswered = take.(:unanswered)
    unsent = take.(:unsent)
    dispatch_name = if transport == :http, do: :streamable_http, else: transport

    %{
      transport: Atom.to_string(transport),
      start_boundary: start_boundary(transport),
      configured: length(records),
      attempted: length(records) - length(unsent),
      answered: length(completed) + length(rejected) + length(error_responses),
      completed: length(completed),
      rejected: length(rejected),
      error_responses: length(error_responses),
      unanswered: length(unanswered),
      unsent: length(unsent),
      errors: details(rejected ++ error_responses),
      reasons: details(unanswered ++ unsent),
      first_send_ms: result.first_send_ms,
      at_first_send: result.at_first_send,
      to_start: percentiles(for {_, sent, _, started, _} <- completed, do: started - sent),
      end_to_end: percentiles(latencies(completed)),
      rejection_latency: percentiles(latencies(rejected)),
      error_latency: percentiles(latencies(error_responses)),
      unanswered_latency: percentiles(latencies(unanswered)),
      execution: percentiles(for {^dispatch_name, duration, _} <- dispatches, do: duration)
    }
  end

  defp start_boundary(:stdio), do: "line enqueued"
  defp start_boundary(:http), do: "Snodo.Client.call_tool/4 called"

  defp latencies(records), do: for({_, sent, at, _, _} <- records, do: at - sent)

  defp details(records) do
    records |> Enum.map(&elem(&1, 4)) |> Enum.frequencies()
  end

  defp percentiles([]), do: nil

  defp percentiles(values) do
    sorted = values |> Enum.sort() |> List.to_tuple()
    size = tuple_size(sorted)
    at = fn q -> elem(sorted, max(ceil(q * size) - 1, 0)) end

    %{
      count: size,
      p50: native_ms(at.(0.50)),
      p95: native_ms(at.(0.95)),
      p99: native_ms(at.(0.99)),
      max: native_ms(elem(sorted, size - 1))
    }
  end

  defp native_ms(native),
    do: Float.round(System.convert_time_unit(native, :native, :microsecond) / 1_000, 2)

  ## Sampler

  defp start_sampler(executor, interval) do
    spawn_link(fn ->
      sample(executor, interval, %{sampled_max_queued: 0, sampled_max_running: 0, samples: 0})
    end)
  end

  defp sample(executor, interval, acc) do
    acc =
      case stats(executor) do
        %{queued: queued, running: running} when is_integer(queued) ->
          %{
            acc
            | sampled_max_queued: max(acc.sampled_max_queued, queued),
              sampled_max_running: max(acc.sampled_max_running, running),
              samples: acc.samples + 1
          }

        _executor_down ->
          acc
      end

    receive do
      {:stop, from} -> send(from, {:samples, self(), acc})
    after
      interval -> sample(executor, interval, acc)
    end
  end

  defp stop_sampler(sampler) do
    send(sampler, {:stop, self()})

    receive do
      {:samples, ^sampler, acc} -> acc
    end
  end

  # Unlinks first, so stopping a helper never sends the caller an exit signal.
  defp stop_linked(pid) do
    Process.unlink(pid)
    Process.exit(pid, :kill)
  end

  defp stop_process(pid, reason \\ :normal) do
    GenServer.stop(pid, reason, @drain_ms + 5_000)
  catch
    :exit, _already_stopped -> :ok
  end

  defp system_info do
    %{
      otp: System.otp_release(),
      elixir: System.version(),
      schedulers: System.schedulers_online(),
      system: :erlang.system_info(:system_architecture) |> to_string(),
      somaxconn: somaxconn()
    }
  end

  # The kernel caps a listen backlog at this value on Linux.
  defp somaxconn do
    case File.read("/proc/sys/net/core/somaxconn") do
      {:ok, value} -> value |> String.trim() |> String.to_integer()
      {:error, _reason} -> nil
    end
  end

  ## Validation

  # {key, minimum, maximum}. Timer values are capped at what Erlang timers
  # accept, the backlog at what a socket option holds.
  @bounds [
    {:requests, 1, 10_000_000},
    {:concurrency, 1, 100_000},
    {:delay_ms, 0, @max_timer},
    {:max_concurrency, 1, 10_000_000},
    {:max_queue, 0, 10_000_000},
    {:request_timeout, 0, @max_timer},
    {:client_timeout, 1, @max_timer},
    {:sample_ms, 1, @max_timer},
    {:backlog, 1, 65_535},
    {:stagger_ms, 0, @max_timer}
  ]

  defp validate!(opts) do
    Enum.each(@bounds, fn {key, min, max} -> check!(key, opts[key], min, max) end)

    for key <- [:stdio_requests, :http_requests],
        opts[key] != nil,
        do: check!(key, opts[key], 1, 10_000_000)

    transports = opts[:transports]

    unless is_list(transports) and transports != [] and
             transports -- [:stdio, :http] == [] and Enum.uniq(transports) == transports do
      raise ArgumentError, "--transport must be stdio or http, each at most once"
    end

    :ok
  end

  defp check!(key, value, min, max) do
    unless is_integer(value) and value >= min and value <= max do
      raise ArgumentError,
            "--#{String.replace(Atom.to_string(key), "_", "-")} must be an integer " <>
              "from #{min} to #{max}, got #{inspect(value)}"
    end
  end
end
