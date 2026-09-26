defmodule Snodo.Transport.Stdio do
  @moduledoc """
  Concurrent newline-delimited JSON-RPC transport.

  A small coordinator owns framing and serializes complete stdout writes. Work
  is admitted through the optional, transport-neutral `Snodo.Server.Executor`, so
  the coordinator never awaits a handler and execution policy is reusable by
  other transports.

  `:write_timeout` is a positive millisecond limit, defaulting to 5,000. A single
  linked, monitored helper performs each write while the coordinator waits
  boundedly; there is no writer queue. Cancellation and EOF handling can wait
  up to this limit during a blocked write. A timeout or output error is terminal:
  the transport cancels its work and closes subscriptions, without attempting
  further writes. A timed-out device may already have accepted some bytes, so
  the transport never retries. Supplied I/O devices are never stopped or killed.
  """

  @behaviour Snodo.Transport
  use GenServer

  alias Snodo.Envelope
  alias Snodo.Error
  alias Snodo.Progress
  alias Snodo.Server
  alias Snodo.Server.Executor
  alias Snodo.Server.Runtime
  alias Snodo.Subscription
  alias Snodo.Transport.Context, as: TransportContext
  alias Snodo.Transport.Stdio.Framing

  @type state :: %{
          runtime: Runtime.t(),
          input: IO.device(),
          output: IO.device(),
          writer: {IO.device(), pos_integer()},
          executor: pid(),
          executor_monitor: reference() | nil,
          serve_owner_monitor: reference() | nil,
          owns_executor?: boolean(),
          request_timeout: Executor.execution_timeout() | :default,
          reader: pid() | nil,
          connection_ref: reference(),
          executions_by_id: map(),
          executions_by_ref: map(),
          subscriptions_by_id: map(),
          subscriptions_by_worker: map(),
          max_subscriptions: pos_integer(),
          eof?: boolean()
        }

  @impl true
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc "Runs the stdio transport until EOF and all admitted requests finish."
  @spec serve(Runtime.t(), keyword()) :: :ok | {:error, term()}
  def serve(%Runtime{} = runtime, opts \\ []) do
    opts =
      opts
      |> Keyword.put(:runtime, runtime)
      |> Keyword.put(:defer_reader?, true)
      |> Keyword.put(:serve_owner, self())

    case GenServer.start(__MODULE__, opts, Keyword.take(opts, [:name])) do
      {:ok, pid} ->
        monitor = Process.monitor(pid)
        :ok = GenServer.call(pid, :start_reader)

        receive do
          {:DOWN, ^monitor, :process, ^pid, :normal} -> :ok
          {:DOWN, ^monitor, :process, ^pid, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }
  end

  @impl true
  def init(opts) do
    _previous_trap_exit = Process.flag(:trap_exit, true)
    runtime = Keyword.fetch!(opts, :runtime)
    input = Keyword.get(opts, :input, :stdio)
    output = Keyword.get(opts, :output, :stdio)
    write_timeout = validate_write_timeout!(Keyword.get(opts, :write_timeout, 5_000))
    connection_ref = Keyword.get_lazy(opts, :connection_ref, &make_ref/0)
    :ok = maybe_redirect_default_logger(opts, output)
    {:ok, executor, owns_executor?} = start_executor(opts)
    executor_monitor = Process.monitor(executor)
    serve_owner_monitor = monitor_optional_owner(Keyword.get(opts, :serve_owner))

    reader =
      if Keyword.get(opts, :defer_reader?, false),
        do: nil,
        else: start_reader(input)

    {:ok,
     %{
       runtime: runtime,
       input: input,
       output: output,
       writer: {output, write_timeout},
       executor: executor,
       executor_monitor: executor_monitor,
       serve_owner_monitor: serve_owner_monitor,
       owns_executor?: owns_executor?,
       request_timeout: Keyword.get(opts, :request_timeout, :default),
       reader: reader,
       connection_ref: connection_ref,
       executions_by_id: %{},
       executions_by_ref: %{},
       subscriptions_by_id: %{},
       subscriptions_by_worker: %{},
       max_subscriptions: validate_max_subscriptions!(Keyword.get(opts, :max_subscriptions, 32)),
       eof?: false
     }}
  end

  @impl true
  def handle_call(:start_reader, _from, %{reader: nil} = state) do
    {:reply, :ok, %{state | reader: start_reader(state.input)}}
  end

  def handle_call(:start_reader, _from, state), do: {:reply, :ok, state}

  def handle_call({:mcp_progress, sink_ref, report}, from, state) do
    case Enum.find(state.executions_by_ref, fn {_ref, entry} ->
           entry.progress.sink.reference == sink_ref
         end) do
      {reference, entry} ->
        handle_progress(state, reference, entry, from, report)

      nil ->
        :ok = Progress.reply(from, report, {:error, :closed})
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:stdio_line, line}, state) do
    case Framing.decode_line(line) do
      {:ok, message} ->
        handle_message(message, state)

      {:error, %Error{} = error} ->
        write_error(state.writer, error)
        {:noreply, state}
    end
  end

  def handle_info(:stdio_eof, state) do
    state
    |> close_all_subscriptions(:disconnected)
    |> Map.put(:eof?, true)
    |> maybe_stop()
  end

  def handle_info(
        {:mcp_execution, executor, reference, _key, outcome},
        %{executor: executor} = state
      ) do
    case Map.pop(state.executions_by_ref, reference) do
      {nil, _executions_by_ref} ->
        {:noreply, state}

      {entry, executions_by_ref} ->
        :ok = Progress.close(entry.progress.sink)

        state =
          state
          |> Map.put(:executions_by_ref, executions_by_ref)
          |> delete_execution_id(entry.id, reference)

        handle_execution_outcome(state, entry, outcome)
    end
  end

  def handle_info({:mcp_subscription, worker, outcome}, state) do
    case Map.fetch(state.subscriptions_by_worker, worker) do
      {:ok, id} -> handle_subscription_outcome(state, id, outcome)
      :error -> {:noreply, state}
    end
  end

  def handle_info({:stdio_read_error, _reason}, state) do
    write_error(state.writer, Error.parse_error("Failed to read stdio input"))
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, monitor, :process, executor, reason},
        %{executor: executor, executor_monitor: monitor} = state
      ) do
    state = fail_pending_executions(state, reason)
    {:stop, {:executor_down, reason}, state}
  end

  def handle_info({:DOWN, monitor, :process, worker, reason}, state)
      when is_map_key(state.subscriptions_by_worker, worker) do
    case Map.fetch(state.subscriptions_by_worker, worker) do
      {:ok, id} ->
        case Map.fetch(state.subscriptions_by_id, id) do
          {:ok, %{monitor: ^monitor, subscription: subscription}} ->
            write_response(state.writer, Subscription.failure(subscription, reason))

            state
            |> remove_subscription(id, {:error, reason}, false)
            |> maybe_stop()

          _stale ->
            {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:DOWN, monitor, :process, _owner, reason},
        %{serve_owner_monitor: monitor} = state
      ) do
    {:stop, {:serve_owner_down, reason}, state}
  end

  def handle_info({:EXIT, executor, _reason}, %{executor: executor} = state) do
    {:noreply, state}
  end

  def handle_info({:EXIT, reader, :normal}, %{reader: reader} = state) do
    {:noreply, state}
  end

  def handle_info({:EXIT, reader, _reason}, %{reader: reader} = state) do
    write_error(state.writer, Error.parse_error("Stdio reader terminated unexpectedly"))

    state
    |> close_all_subscriptions(:disconnected)
    |> Map.put(:eof?, true)
    |> maybe_stop()
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.executions_by_ref, fn {_reference, entry} ->
      Progress.close(entry.progress.sink)
    end)

    Enum.each(state.executions_by_ref, fn {_reference, entry} ->
      cancel_execution(state.executor, entry.key, :transport_closed)
    end)

    demonitor_optional(state.executor_monitor)
    demonitor_optional(state.serve_owner_monitor)

    if is_pid(state.reader) and Process.alive?(state.reader),
      do: Process.exit(state.reader, :shutdown)

    if state.owns_executor?, do: stop_executor(state.executor)

    _state = close_all_subscriptions(state, :disconnected)

    :ok
  end

  defp fail_pending_executions(state, reason) do
    Enum.each(state.executions_by_ref, fn {_reference, entry} ->
      :ok = Progress.close(entry.progress.sink)

      write_execution_outcome(
        state.writer,
        state.runtime,
        entry,
        {:failed, {:executor_down, reason}}
      )
    end)

    %{state | executions_by_id: %{}, executions_by_ref: %{}}
  end

  # A response object is not work: it must not occupy the client's id or
  # produce a reply.
  defp handle_message(message, state) do
    if Envelope.response?(message),
      do: {:noreply, state},
      else: handle_request_or_notification(message, state)
  end

  defp handle_request_or_notification(message, state) do
    id = request_id(message)

    case {id, Server.resolve_notification(state.runtime, message, transport_context(state))} do
      {nil, {:ok, {:cancel, request_id, reason}}} ->
        {:noreply, cancel_request(state, request_id, reason)}

      {request_id, _classification}
      when not is_nil(request_id) and
             (is_map_key(state.executions_by_id, request_id) or
                is_map_key(state.subscriptions_by_id, request_id)) ->
        write_rejection(
          state.writer,
          state.runtime,
          message,
          transport_context(state),
          Error.invalid_request("Duplicate in-flight request id")
        )

        {:noreply, state}

      {_id, _classification} ->
        {:noreply, start_request(state, message, id)}
    end
  end

  defp start_request(state, message, id) do
    key = execution_key(state.connection_ref, id)
    runtime = state.runtime
    output = state.output
    sink = Progress.sink(self())
    transport = transport_context(state, %{progress_sink: sink})

    work = fn cancellation ->
      route_raw_io_to_stderr(output)
      transport = put_in(transport.metadata[:cancellation], cancellation)

      try do
        Server.dispatch(runtime, message, transport)
      after
        Progress.close(sink)
      end
    end

    case submit_execution(state.executor, key, work, state.request_timeout) do
      {:ok, reference} ->
        state
        |> Map.update!(:executions_by_ref, fn executions ->
          entry = %{
            id: id,
            key: key,
            message: message,
            transport: transport,
            progress: Progress.state(sink)
          }

          Map.put(executions, reference, entry)
        end)
        |> maybe_put_execution_id(id, reference)

      {:error, :overloaded} ->
        write_rejection(
          state.writer,
          runtime,
          message,
          transport,
          Error.internal("Server execution capacity exhausted")
        )

        state

      {:error, :duplicate_key} ->
        write_rejection(
          state.writer,
          runtime,
          message,
          transport,
          Error.invalid_request("Duplicate in-flight request id")
        )

        state

      {:error, {:executor_unavailable, reason}} ->
        write_rejection(
          state.writer,
          runtime,
          message,
          transport,
          Error.internal("Request executor unavailable", reason)
        )

        mark_executor_unavailable(state)
    end
  end

  defp cancel_request(state, request_id, reason) do
    case Map.fetch(state.subscriptions_by_id, request_id) do
      {:ok, _entry} ->
        remove_subscription(state, request_id, {:cancelled, reason})

      :error ->
        with {:ok, reference} <- Map.fetch(state.executions_by_id, request_id),
             {:ok, %{key: key} = entry} <- Map.fetch(state.executions_by_ref, reference),
             :ok <- cancel_execution(state.executor, key, reason) do
          :ok = Progress.close(entry.progress.sink)

          state
          |> Map.update!(:executions_by_ref, &Map.delete(&1, reference))
          |> delete_execution_id(request_id, reference)
        else
          _missing_or_already_finished -> state
        end
    end
  end

  defp handle_progress(state, reference, entry, from, report) do
    case Progress.accept(entry.progress, from, report) do
      {:ok, notification, progress} ->
        case write_progress(state.writer, notification) do
          :ok ->
            :ok = Progress.reply(from, report, :ok)
            entry = %{entry | progress: progress}
            {:noreply, put_in(state.executions_by_ref[reference], entry)}

          {:error, reason} ->
            :ok = Progress.close(entry.progress.sink)
            :ok = Progress.reply(from, report, {:error, :closed})
            {:stop, {:output_failed, reason}, state}
        end

      {:error, reason} ->
        :ok = Progress.reply(from, report, {:error, reason})
        {:noreply, state}
    end
  end

  defp write_progress(output, notification) do
    write_response(output, notification)
  catch
    :exit, {:output_failed, reason} -> {:error, reason}
    kind, reason -> {:error, {kind, reason}}
  end

  defp request_id(message) when is_map(message) do
    case Map.fetch(message, "id") do
      {:ok, id} when is_binary(id) or is_integer(id) -> id
      _notification_or_invalid -> nil
    end
  end

  defp request_id(_message), do: nil

  defp transport_context(state, metadata \\ %{}) do
    %TransportContext{
      transport: :stdio,
      connection_ref: state.connection_ref,
      metadata: metadata
    }
  end

  defp maybe_put_execution_id(state, nil, _reference), do: state

  defp maybe_put_execution_id(state, id, reference) do
    Map.update!(state, :executions_by_id, &Map.put(&1, id, reference))
  end

  defp delete_execution_id(state, nil, _reference), do: state

  defp delete_execution_id(state, id, reference) do
    Map.update!(state, :executions_by_id, fn executions ->
      case executions do
        %{^id => ^reference} -> Map.delete(executions, id)
        _other -> executions
      end
    end)
  end

  defp maybe_stop(
         %{
           eof?: true,
           executions_by_ref: executions,
           subscriptions_by_id: subscriptions
         } = state
       )
       when map_size(executions) == 0 and map_size(subscriptions) == 0,
       do: {:stop, :normal, state}

  defp maybe_stop(state), do: {:noreply, state}

  defp maybe_write(_output, nil), do: :ok
  defp maybe_write(output, response), do: write_response(output, response)

  defp write_execution_outcome(_output, _runtime, _entry, {:cancelled, _reason}), do: :ok

  defp write_execution_outcome(output, _runtime, _entry, {:completed, {:ok, response}}) do
    maybe_write(output, response)
  end

  defp write_execution_outcome(output, runtime, entry, {:timed_out, _timeout}) do
    write_rejection(
      output,
      runtime,
      entry.message,
      entry.transport,
      Error.internal("Request execution timed out")
    )
  end

  defp write_execution_outcome(output, runtime, entry, {:failed, reason}) do
    write_rejection(
      output,
      runtime,
      entry.message,
      entry.transport,
      Error.internal("Request worker failed", reason)
    )
  end

  defp write_execution_outcome(output, runtime, entry, {:completed, invalid_result}) do
    write_rejection(
      output,
      runtime,
      entry.message,
      entry.transport,
      Error.internal("Request worker returned an invalid result", invalid_result)
    )
  end

  defp handle_execution_outcome(state, entry, {:completed, {:stream, subscription}}) do
    start_subscription(state, entry, subscription)
  end

  defp handle_execution_outcome(state, entry, outcome) do
    write_execution_outcome(state.writer, state.runtime, entry, outcome)
    maybe_stop(state)
  end

  defp start_subscription(%{eof?: true} = state, _entry, subscription) do
    :ok = Subscription.close(subscription, :disconnected)
    maybe_stop(state)
  end

  defp start_subscription(state, entry, subscription) do
    if map_size(state.subscriptions_by_id) >= state.max_subscriptions do
      :ok = Subscription.close(subscription, {:error, :overloaded})

      write_rejection(
        state.writer,
        state.runtime,
        entry.message,
        entry.transport,
        Error.internal("Server subscription capacity exhausted")
      )

      maybe_stop(state)
    else
      case Subscription.acknowledgement(subscription) do
        {:ok, acknowledgement} ->
          start_acknowledged_subscription(state, subscription, acknowledgement)

        {:error, error} ->
          :ok = Subscription.close(subscription, {:error, error})
          write_response(state.writer, Subscription.failure(subscription, error))
          maybe_stop(state)
      end
    end
  end

  defp start_acknowledged_subscription(state, subscription, acknowledgement) do
    case write_progress(state.writer, acknowledgement) do
      :ok ->
        {worker, monitor} = Subscription.start_worker(subscription, self())
        :ok = Subscription.continue(worker)
        id = subscription.id
        entry = %{subscription: subscription, worker: worker, monitor: monitor}

        state =
          state
          |> Map.update!(:subscriptions_by_id, &Map.put(&1, id, entry))
          |> Map.update!(:subscriptions_by_worker, &Map.put(&1, worker, id))

        {:noreply, state}

      {:error, reason} ->
        :ok = Subscription.close(subscription, {:error, {:output_failed, reason}})
        {:stop, {:output_failed, reason}, state}
    end
  end

  defp handle_subscription_outcome(state, id, {:ok, event}) do
    %{subscription: subscription, worker: worker} = Map.fetch!(state.subscriptions_by_id, id)

    case Subscription.notification(subscription, event) do
      {:ok, notification} ->
        write_response(state.writer, notification)
        :ok = Subscription.continue(worker)
        {:noreply, state}

      :drop ->
        :ok = Subscription.continue(worker)
        {:noreply, state}

      {:error, error} ->
        write_response(state.writer, Subscription.failure(subscription, error))

        state
        |> remove_subscription(id, {:error, error})
        |> maybe_stop()
    end
  end

  defp handle_subscription_outcome(state, id, :closed) do
    %{subscription: subscription} = Map.fetch!(state.subscriptions_by_id, id)

    case Subscription.completion(subscription) do
      {:ok, completion} -> write_response(state.writer, completion)
      {:error, error} -> write_response(state.writer, Subscription.failure(subscription, error))
    end

    state
    |> remove_subscription(id, :complete)
    |> maybe_stop()
  end

  defp handle_subscription_outcome(state, id, {:error, reason}) do
    %{subscription: subscription} = Map.fetch!(state.subscriptions_by_id, id)
    write_response(state.writer, Subscription.failure(subscription, reason))

    state
    |> remove_subscription(id, {:error, reason})
    |> maybe_stop()
  end

  defp remove_subscription(state, id, reason, stop_worker? \\ true) do
    case Map.pop(state.subscriptions_by_id, id) do
      {nil, _subscriptions} ->
        state

      {%{subscription: subscription, worker: worker, monitor: monitor}, subscriptions} ->
        :ok = Subscription.close(subscription, reason)

        if stop_worker? do
          Subscription.stop_worker(worker, monitor)
        else
          Process.demonitor(monitor, [:flush])
        end

        %{
          state
          | subscriptions_by_id: subscriptions,
            subscriptions_by_worker: Map.delete(state.subscriptions_by_worker, worker)
        }
    end
  end

  defp close_all_subscriptions(state, reason) do
    Enum.reduce(Map.keys(state.subscriptions_by_id), state, fn id, next_state ->
      remove_subscription(next_state, id, reason)
    end)
  end

  defp write_rejection(output, runtime, message, transport, error) do
    {:ok, response} = Server.reject(runtime, message, transport, error)
    maybe_write(output, response)
  end

  defp write_error(output, error) do
    write_response(output, %{"jsonrpc" => "2.0", "id" => nil, "error" => Error.to_json_rpc(error)})
  end

  defp write_response({output, timeout}, response) do
    data = Framing.encode_message(response)
    owner = self()

    {writer, monitor} =
      Process.spawn(
        fn -> send(owner, {:stdio_write_result, self(), write_device(output, data)}) end,
        [:link, :monitor]
      )

    try do
      receive do
        {:stdio_write_result, ^writer, :ok} ->
          :ok

        {:stdio_write_result, ^writer, {:error, reason}} ->
          exit({:output_failed, reason})

        {:DOWN, ^monitor, :process, ^writer, reason} ->
          exit({:output_failed, {:writer_down, reason}})
      after
        timeout -> exit({:output_failed, :timeout})
      end
    after
      Process.exit(writer, :kill)
      Process.unlink(writer)
      Process.demonitor(monitor, [:flush])

      receive do
        {:EXIT, ^writer, _reason} -> :ok
      after
        0 -> :ok
      end
    end
  end

  defp write_device(output, data) do
    IO.binwrite(output, data)
  catch
    :error, reason -> {:error, reason}
    kind, reason -> {:error, {kind, reason}}
  end

  defp start_reader(input) do
    owner = self()
    spawn_link(fn -> read_lines(input, read_mode(input), owner) end)
  end

  # `:stdio` is a Latin-1 device when the VM's stdin is a pipe, and IO.read/2
  # would then turn each byte of a UTF-8 character into a character of its
  # own. IO.binread/2 returns the bytes unchanged. Unicode devices, and
  # devices that do not report an encoding, keep IO.read/2.
  defp read_mode(input) do
    case :io.getopts(io_device(input)) do
      options when is_list(options) ->
        if Keyword.get(options, :encoding) == :latin1, do: :bytes, else: :characters

      _unsupported ->
        :characters
    end
  end

  defp io_device(:stdio), do: :standard_io
  defp io_device(device), do: device

  defp execution_key(connection_ref, nil), do: {:stdio, connection_ref, make_ref()}
  defp execution_key(connection_ref, id), do: {:stdio, connection_ref, id}

  defp submit_execution(executor, key, work, timeout) do
    Executor.submit(executor, key, work, timeout: timeout)
  catch
    :exit, reason -> {:error, {:executor_unavailable, reason}}
  end

  defp cancel_execution(executor, key, reason) do
    Executor.cancel(executor, key, reason)
  catch
    :exit, exit_reason -> {:error, {:executor_unavailable, exit_reason}}
  end

  defp monitor_optional_owner(owner) when is_pid(owner), do: Process.monitor(owner)
  defp monitor_optional_owner(nil), do: nil

  defp demonitor_optional(nil), do: :ok

  defp demonitor_optional(monitor) do
    Process.demonitor(monitor, [:flush])
    :ok
  end

  defp mark_executor_unavailable(%{executor_monitor: nil} = state), do: state

  defp mark_executor_unavailable(state) do
    demonitor_optional(state.executor_monitor)
    %{state | executor_monitor: nil}
  end

  defp stop_executor(executor) do
    if Process.alive?(executor), do: GenServer.stop(executor, :normal)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp start_executor(opts) do
    case Keyword.get(opts, :executor) do
      executor when is_pid(executor) ->
        {:ok, executor, false}

      nil ->
        with {:ok, executor} <- Executor.start_link(executor_options(opts)) do
          {:ok, executor, true}
        end

      _invalid ->
        {:error, :invalid_executor}
    end
  end

  defp executor_options(opts) do
    options = Keyword.take(opts, [:max_concurrency, :max_queue])

    case Keyword.get(opts, :request_timeout, :default) do
      :default -> options
      timeout -> Keyword.put(options, :default_timeout, timeout)
    end
  end

  defp validate_max_subscriptions!(value) when is_integer(value) and value > 0, do: value

  defp validate_max_subscriptions!(_invalid) do
    raise ArgumentError, ":max_subscriptions must be a positive integer"
  end

  defp validate_write_timeout!(value) when is_integer(value) and value > 0, do: value

  defp validate_write_timeout!(_invalid) do
    raise ArgumentError, ":write_timeout must be a positive integer"
  end

  defp route_raw_io_to_stderr(:stdio) do
    case Process.whereis(:standard_error) do
      device when is_pid(device) -> Process.group_leader(self(), device)
      nil -> :ok
    end
  end

  defp route_raw_io_to_stderr(_custom_output), do: :ok

  defp maybe_redirect_default_logger(opts, :stdio) do
    if Keyword.get(opts, :redirect_logger?, true) do
      redirect_default_logger_to_stderr()
    else
      :ok
    end
  end

  defp maybe_redirect_default_logger(_opts, _custom_output), do: :ok

  defp redirect_default_logger_to_stderr do
    case :logger.get_handler_config(:default) do
      {:ok, %{module: :logger_std_h, config: %{type: :standard_io}} = handler} ->
        replacement =
          handler
          |> Map.drop([:id, :module])
          |> put_in([:config, :type], :standard_error)

        with :ok <- :logger.remove_handler(:default) do
          :logger.add_handler(:default, :logger_std_h, replacement)
        end

      _already_redirected_or_custom ->
        :ok
    end
  end

  defp read_lines(input, mode, owner) do
    case read_line(input, mode) do
      data when is_binary(data) ->
        send(owner, {:stdio_line, data})
        read_lines(input, mode, owner)

      :eof ->
        send(owner, :stdio_eof)

      {:error, reason} ->
        send(owner, {:stdio_read_error, reason})
        send(owner, :stdio_eof)
    end
  end

  defp read_line(input, :bytes), do: IO.binread(input, :line)
  defp read_line(input, :characters), do: IO.read(input, :line)
end
