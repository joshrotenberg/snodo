defmodule MCP.Progress do
  @moduledoc """
  Acknowledged progress reporting for an active ordinary MCP request.

  Application handlers call `report/3` using their request context. A client must
  have supplied a string/integer `progressToken`, and the transport must have
  installed a sink. Otherwise reporting valid values is a harmless no-op.

  Only the original request worker may report. Each sink permits one outstanding
  update, acknowledged only after its transport writes it. Values must increase
  strictly. The defaults cap each request at 1,000 updates, messages at 4 KiB,
  and each acknowledgement wait at five seconds. Timeout does not clear the
  outstanding-update gate, so retrying cannot grow an unbounded mailbox.

  The transport owns `state/1`, handles `:mcp_progress` synchronous call messages
  with `accept/3`, writes their notification, then calls `reply/3`. It closes the
  sink after execution, cancellation, disconnect, or a failed write. No process
  is started by this module, and the synchronous protocol core is unchanged.
  """

  alias MCP.Cancellation
  alias MCP.Context
  alias MCP.JSONValue
  alias MCP.Progress.Sink
  alias MCP.Progress.State

  @enforce_keys [:sink, :producer, :token, :context]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{
            sink: Sink.t(),
            producer: pid(),
            token: String.t() | integer(),
            context: Context.t()
          }
  @type report :: %{binding: t(), fields: map()}
  @type result :: :ok | {:error, atom()}

  @doc "Creates an inactive-until-bound sink handle for an existing transport owner."
  @spec sink(pid(), keyword()) :: Sink.t()
  def sink(owner, options \\ []) when is_pid(owner) and is_list(options) do
    limits = [timeout: 5_000, max_updates: 1_000, max_message_bytes: 4_096]

    unless Keyword.keyword?(options) and Keyword.keys(options) -- Keyword.keys(limits) == [],
      do: raise(ArgumentError, "unknown progress sink option")

    limits = Keyword.merge(limits, options)

    unless Enum.all?(limits, fn {_key, value} -> is_integer(value) and value > 0 end),
      do: raise(ArgumentError, "progress sink limits must be positive integers")

    struct!(
      Sink,
      [owner: owner, reference: make_ref(), lifecycle: :atomics.new(3, signed: false)] ++ limits
    )
  end

  @doc "Initializes counters retained by the transport owning the sink."
  @spec state(Sink.t()) :: State.t()
  def state(%Sink{} = sink), do: %State{sink: sink}

  @doc "Binds an installed sink to a validated request context and its current worker."
  @spec bind(term(), Context.t()) :: t() | nil
  def bind(%Sink{} = sink, %Context{} = context) do
    token = context.metadata["progressToken"]

    if not is_nil(context.request_id) and (is_binary(token) or is_integer(token)) and
         Code.ensure_loaded?(context.protocol) and
         function_exported?(context.protocol, :shape_progress, 3) and
         :atomics.get(sink.lifecycle, 1) == 0 and
         :atomics.compare_exchange(sink.lifecycle, 3, 0, 1) == :ok do
      %__MODULE__{sink: sink, producer: self(), token: token, context: %{context | progress: nil}}
    end
  end

  def bind(_no_sink, %Context{}), do: nil

  @doc "Reports increasing progress, optionally including numeric total and a human-readable message."
  @spec report(Context.t(), number(), keyword()) :: result()
  def report(context, value, options \\ [])

  def report(%Context{progress: binding}, value, options) do
    with {:ok, fields} <- fields(value, options) do
      deliver(binding, fields)
    end
  end

  @doc "Marks a sink terminal. Safe to call repeatedly from transport cleanup paths."
  @spec close(Sink.t()) :: :ok
  def close(%Sink{lifecycle: lifecycle}), do: :atomics.put(lifecycle, 1, 1)

  @doc """
  Admits a synchronous report in the transport owner before writing it.

  `from` is the original `GenServer.from()` received with the progress call.
  The returned state belongs to the transport. Complete the acknowledgement
  with `reply/3` only after the write succeeds or fails.
  """
  @spec accept(State.t(), GenServer.from(), report()) ::
          {:ok, map(), State.t()} | {:error, atom()}
  def accept(%State{sink: sink} = state, {caller, _tag}, %{binding: binding, fields: fields}) do
    with :ok <- validate_binding(sink, binding, caller),
         :ok <- active(binding),
         :ok <- validate_fields(fields, sink),
         :ok <- increasing(state.last, fields["progress"]),
         :ok <- under_limit(state),
         {:ok, notification} <- notification(binding, fields) do
      {:ok, notification, %{state | last: fields["progress"], count: state.count + 1}}
    end
  end

  def accept(%State{}, _from, _report), do: {:error, :invalid_report}

  @doc "Acknowledges a consumed report after writing, releasing its one-outstanding-update gate."
  @spec reply(GenServer.from(), report(), result()) :: :ok
  def reply(from, %{binding: %__MODULE__{sink: sink}}, result) do
    :ok = :atomics.put(sink.lifecycle, 2, 0)
    GenServer.reply(from, result)
  end

  def reply(from, _invalid, result), do: GenServer.reply(from, result)

  defp fields(value, options) when is_number(value) and is_list(options) do
    if Keyword.keyword?(options) and Keyword.keys(options) -- [:total, :message] == [] do
      fields = Map.new(options, fn {key, value} -> {Atom.to_string(key), value} end)
      fields = Map.put(fields, "progress", value)

      case basic_fields?(fields) do
        true -> {:ok, fields}
        false -> {:error, :invalid_progress}
      end
    else
      {:error, :invalid_progress}
    end
  end

  defp fields(_value, _options), do: {:error, :invalid_progress}

  defp basic_fields?(fields) do
    is_number(fields["progress"]) and
      (not Map.has_key?(fields, "total") or is_number(fields["total"])) and
      (not Map.has_key?(fields, "message") or
         (is_binary(fields["message"]) and String.valid?(fields["message"])))
  end

  defp deliver(nil, _fields), do: :ok

  defp deliver(%__MODULE__{} = binding, fields) do
    with :ok <- original_worker(binding),
         :ok <- active(binding),
         :ok <- validate_fields(fields, binding.sink),
         :ok <- acquire(binding.sink) do
      call_owner(binding, fields)
    end
  end

  defp deliver(_unrecognized, _fields), do: :ok

  defp original_worker(%{producer: producer}) do
    if producer == self(), do: :ok, else: {:error, :wrong_process}
  end

  defp active(%{sink: sink, context: context}) do
    cond do
      :atomics.get(sink.lifecycle, 1) != 0 -> {:error, :closed}
      cancelled?(context.cancellation) -> {:error, :cancelled}
      true -> :ok
    end
  end

  defp cancelled?(value) do
    case Cancellation.normalize(value) do
      {:ok, token} -> Cancellation.cancelled?(token)
      :error -> false
    end
  end

  defp acquire(%Sink{lifecycle: lifecycle}) do
    case :atomics.compare_exchange(lifecycle, 2, 0, 1) do
      :ok -> :ok
      _busy -> {:error, :busy}
    end
  end

  defp call_owner(%{sink: sink} = binding, fields) do
    report = %{binding: binding, fields: fields}
    GenServer.call(sink.owner, {:mcp_progress, sink.reference, report}, sink.timeout)
  catch
    :exit, {:timeout, _call} ->
      {:error, :timeout}

    :exit, _unavailable ->
      :ok = close(sink)
      {:error, :closed}
  end

  defp validate_binding(%Sink{owner: owner} = sink, binding, caller) do
    case binding do
      %__MODULE__{sink: ^sink, producer: ^caller} when owner == self() -> :ok
      _wrong -> {:error, :wrong_sink}
    end
  end

  defp validate_fields(fields, sink) when is_map(fields) do
    if basic_fields?(fields) and Map.keys(fields) -- ["progress", "total", "message"] == [] and
         byte_size(Map.get(fields, "message", "")) <= sink.max_message_bytes,
       do: :ok,
       else: {:error, :invalid_progress}
  end

  defp validate_fields(_fields, _sink), do: {:error, :invalid_progress}

  defp increasing(nil, _next), do: :ok
  defp increasing(last, next) when next > last, do: :ok
  defp increasing(_last, _next), do: {:error, :not_increasing}

  defp under_limit(%State{count: count, sink: %{max_updates: maximum}}) when count < maximum,
    do: :ok

  defp under_limit(_state), do: {:error, :limit_reached}

  defp notification(%{token: token, context: context}, fields) do
    notification = context.protocol.shape_progress(token, fields, context)

    if is_map(notification) and JSONValue.valid?(notification),
      do: {:ok, notification},
      else: {:error, :invalid_notification}
  catch
    _kind, _reason -> {:error, :invalid_notification}
  end
end
