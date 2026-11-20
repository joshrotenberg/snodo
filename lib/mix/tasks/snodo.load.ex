defmodule Mix.Tasks.Snodo.Load do
  use Mix.Task

  @shortdoc "Drives concurrent requests through the stdio and HTTP transports' executor"

  @switches [
    requests: :integer,
    concurrency: :integer,
    delay_ms: :integer,
    max_concurrency: :integer,
    max_queue: :integer,
    request_timeout: :integer,
    client_timeout: :integer,
    sample_ms: :integer,
    backlog: :integer,
    warmup: :boolean,
    transport: :keep,
    stdio_requests: :integer,
    http_requests: :integer,
    shared: :boolean,
    stagger_ms: :integer,
    allow_unanswered: :boolean,
    json: :boolean
  ]

  @moduledoc """
  Sends concurrent `tools/call` requests through the stdio transport and the
  native Streamable HTTP listener into one `Snodo.Server.Executor`, and reports
  what happened to each request, how long requests took to reach their
  handler, end-to-end latency, the executor's sampled queue depth, and the
  errors returned.

      mix snodo.load
      mix snodo.load --max-concurrency 64 --max-queue 2000
      mix snodo.load --transport http --requests 5000 --concurrency 500
      mix snodo.load --shared --http-requests 50 --stagger-ms 20 --json

  It is not part of `mix quality`.

  ## Outcomes and exit status

  Every configured request ends in one outcome:

    * answered: a result (completed), a refusal for capacity (rejected), or
      any other JSON-RPC error the server returned (error response), such as
      the HTTP listener's request timeout;
    * unanswered: the peer gave up, after `--client-timeout` with no reply or
      on a client transport error such as a refused connection;
    * unsent: never sent, because the stdio server exited first.

  The task exits with an error when any request is unanswered or unsent,
  unless `--allow-unanswered` is given. Rejections and other server error
  responses are answers and do not fail the run. It also fails when the
  warm-up does not complete every request, or when a transport cannot be
  set up.

  ## Options

  Defaults reproduce 1,000 concurrent requests against the executor's default
  limits:

    * `--requests` - requests per transport, default 1,000.
    * `--concurrency` - requests each peer keeps in flight, default 1,000.
      The stdio peer writes that many lines at once and one more per answer
      or timeout; the HTTP peer runs that many `Snodo.Client` callers over a
      pool of that many connections.
    * `--delay-ms` - how long the handler sleeps, default 10.
    * `--max-concurrency` and `--max-queue` - the executor limits, default 32
      and 256 as in `Snodo.Server.Executor`.
    * `--request-timeout` - the execution deadline in milliseconds, default
      30,000. The HTTP listener also applies it to queue wait plus execution.
    * `--client-timeout` - how long a peer waits for each response, default
      60,000.
    * `--sample-ms` - how often `Snodo.Server.Executor.stats/1` is sampled,
      default 5. Samples go through the executor's mailbox, so they report
      sampled maxima that can miss the true peaks, and a shorter interval adds
      load to the process being measured.
    * `--backlog` - the HTTP listener's listen backlog, default 128 as in
      `Snodo.Transport.StreamableHTTP.Server`.
    * `--no-warmup` - skip the 20 untimed requests sent through each transport
      before measuring, which load code so the first scenario is not slower.
    * `--transport` - `stdio` or `http`, repeatable. Default both, one after
      the other, each with a fresh executor.
    * `--stdio-requests` and `--http-requests` - override `--requests` for
      one transport.
    * `--shared` - run the transports against one executor. Both are set up
      first, then their traffic is released.
    * `--stagger-ms` - release each transport's traffic this many milliseconds
      after the one before it, default 0. The report records when each
      transport actually sent its first request and the executor's queue at
      that moment.
    * `--allow-unanswered` - exit successfully even when requests are
      unanswered or unsent.
    * `--json` - print the report as JSON.

  Integer options are checked against the limits of the timers and sockets
  they configure.

  ## Measurements

  "To start" is the time from the peer's send boundary to the handler
  starting, for completed requests only, so it describes the requests that
  got through. On stdio the boundary is the moment the pre-encoded line is
  handed to the input device, and the time includes the transport reading and
  decoding it, admission, and queue wait. On HTTP the boundary is the call to
  `Snodo.Client.call_tool/4`, so it also includes client work, pool checkout,
  and opening a connection. Execution time comes from the
  `[:snodo, :server, :dispatch, :stop]` instrumentation event and excludes
  queue wait. Latencies are in milliseconds.
  """

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if positional != [] or invalid != [] do
      rejected = Enum.map(invalid, &elem(&1, 0)) ++ positional

      Mix.raise(
        "usage: mix snodo.load [options], see mix help snodo.load; " <>
          "not understood: #{Enum.join(rejected, " ")}"
      )
    end

    Mix.Task.run("app.start")

    {json?, opts} = Keyword.pop(opts, :json, false)
    {allow_unanswered?, opts} = Keyword.pop(opts, :allow_unanswered, false)

    report =
      try do
        opts |> load_options() |> Snodo.Load.run()
      rescue
        error in [ArgumentError, Snodo.Load.Error] -> Mix.raise(Exception.message(error))
      end

    if json?, do: Mix.shell().info(JSON.encode!(report)), else: print(report)
    check_outcomes!(report, allow_unanswered?)
    report
  end

  defp check_outcomes!(report, allow_unanswered?) do
    transports = for scenario <- report.scenarios, t <- scenario.transports, do: t
    unanswered = Enum.sum(Enum.map(transports, & &1.unanswered))
    unsent = Enum.sum(Enum.map(transports, & &1.unsent))

    if unanswered + unsent > 0 and not allow_unanswered? do
      Mix.raise(
        "#{unanswered} requests unanswered and #{unsent} unsent; " <>
          "pass --allow-unanswered to accept this"
      )
    end
  end

  defp load_options(opts) do
    case Keyword.get_values(opts, :transport) do
      [] ->
        opts

      names ->
        opts
        |> Keyword.delete(:transport)
        |> Keyword.put(:transports, Enum.map(names, &transport!/1))
    end
  end

  defp transport!("stdio"), do: :stdio
  defp transport!("http"), do: :http

  defp transport!(other),
    do: Mix.raise("--transport must be stdio or http, got #{inspect(other)}")

  defp print(%{config: config, system: system, scenarios: scenarios}) do
    shell = Mix.shell()

    shell.info(
      "snodo.load: #{config.requests} requests, concurrency #{config.concurrency}, " <>
        "handler #{config.delay_ms} ms, executor #{config.max_concurrency}/#{config.max_queue}, " <>
        "backlog #{config.backlog}, OTP #{system.otp}, #{system.schedulers} schedulers"
    )

    Enum.each(scenarios, &print_scenario(shell, &1))
  end

  defp print_scenario(shell, %{executor: executor} = scenario) do
    shell.info(
      "\n#{scenario.name}: #{scenario.wall_ms} ms, sampled max running " <>
        "#{executor.sampled_max_running}, sampled max queued #{executor.sampled_max_queued} " <>
        "(#{executor.samples} samples every #{executor.sample_ms} ms)"
    )

    Enum.each(scenario.transports, &print_transport(shell, &1))
  end

  defp print_transport(shell, t) do
    shell.info(
      "  #{t.transport}: #{t.configured} configured, #{t.attempted} attempted, " <>
        "#{t.answered} answered (#{t.completed} completed, #{t.rejected} rejected, " <>
        "#{t.error_responses} error responses), #{t.unanswered} unanswered, #{t.unsent} unsent"
    )

    shell.info(
      "    first send at #{t.first_send_ms} ms, executor then running " <>
        "#{t.at_first_send.running}, queued #{t.at_first_send.queued}"
    )

    print_latency(shell, "to start (completed, from #{t.start_boundary})", t.to_start)
    print_latency(shell, "end to end (completed)", t.end_to_end)
    print_latency(shell, "rejection", t.rejection_latency)
    print_latency(shell, "error response", t.error_latency)
    print_latency(shell, "unanswered", t.unanswered_latency)
    print_latency(shell, "execution", t.execution)

    for {error, count} <- Enum.sort(t.errors), do: shell.info("    error #{error}: #{count}")

    for {reason, count} <- Enum.sort(t.reasons),
        do: shell.info("    gave up: #{reason}: #{count}")
  end

  defp print_latency(_shell, _label, nil), do: :ok

  defp print_latency(shell, label, stats) do
    shell.info(
      "    #{label}: p50 #{stats.p50} p95 #{stats.p95} " <>
        "p99 #{stats.p99} max #{stats.max} (n=#{stats.count})"
    )
  end
end
