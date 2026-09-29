defmodule Snodo.Client.Subscription do
  @moduledoc """
  A `subscriptions/listen` stream opened with `Snodo.Client.listen/3`.

  The struct is the handle: `accepted` is the filter the server acknowledged,
  `id` the request ID (the subscription ID on the wire), `ref` the tag of the
  messages the stream sends, `owner` the process that opened it, and `pid` the
  transport process that receives the stream.

  ## Messages

  The owner receives `{:snodo_subscription, ref, payload}` with one of:

    * `{:notification, method, params}`: one event, as the server sent it.
      `method` is the notification's method, for example
      `"notifications/resources/updated"`, `"notifications/tools/list_changed"`,
      or an extension's such as `"notifications/tasks"`; `params` is its params
      map, `"_meta"` included.
    * `{:dropped, count}`: `count` events were discarded because the buffer was
      full. It precedes the next delivered event.
    * `{:closed, reason}`: the stream ended. `:complete` is the server's
      terminal result; `{:error, %Snodo.Error{}}` is its terminal error
      response, or a failure of the connection. Nothing follows it.

  ## Demand and the buffer

  Events are sent to the owner only while it has asked for them. `demand/2`
  asks for `n` more, `next/2` asks for one and waits for it, and `stream/1`
  wraps `next/2` as an `Enumerable`. Events that arrive without demand wait in
  the transport process, at most `:max_buffer` of them (100 by default). A
  full buffer follows the `:overflow` policy given to `Snodo.Client.listen/3`:
  `:drop_oldest` (the default) discards the oldest queued event, `:drop_newest`
  discards the arriving one. Either way the owner is told with `{:dropped, n}`.
  `{:closed, reason}` is delivered after the queued events.

  ## Ending the stream

  `close/1` ends the stream from the client side; the server sees a
  cancellation. The owner's exit does the same. No message follows `close/1`;
  events delivered before it stay in the owner's mailbox.
  """

  alias Snodo.Client.Transport
  alias Snodo.Error

  @typedoc "Why a stream ended: the server's terminal result, or an error."
  @type close_reason :: :complete | {:error, Error.t()}

  @typedoc "What the owner receives inside `{:snodo_subscription, ref, payload}`."
  @type payload ::
          {:notification, String.t(), map()}
          | {:dropped, pos_integer()}
          | {:closed, close_reason()}

  @type t :: %__MODULE__{
          ref: reference(),
          id: integer(),
          accepted: map(),
          owner: pid(),
          pid: pid()
        }

  @enforce_keys [:ref, :id, :accepted, :owner, :pid]
  defstruct [:ref, :id, :accepted, :owner, :pid]

  @close_timeout 5_000

  @doc """
  Asks for `n` more events, which arrive as messages to the owner.

  Demand accumulates: queued events are sent at once, up to `n`, and later
  events are sent as they arrive until the demand is used up.
  """
  @spec demand(t(), pos_integer()) :: :ok
  def demand(%__MODULE__{pid: pid, ref: ref}, n) when is_integer(n) and n > 0 do
    send(pid, {:mcp_client_demand, ref, n})
    :ok
  end

  @doc """
  Asks for one event and waits for the next message.

  Returns the payload: `{:notification, method, params}`, `{:dropped, n}`, or
  `{:closed, reason}`. Returns `{:error, :timeout}` when nothing arrives in
  `timeout` milliseconds; the demand stays, so that event arrives as a message
  later and the next call returns it. If the transport process exits, returns
  `{:closed, {:error, %Snodo.Error{}}}`. Must be called by the owner.
  """
  @spec next(t(), timeout()) :: payload() | {:error, :timeout}
  def next(%__MODULE__{ref: ref} = subscription, timeout \\ :infinity) do
    owner!(subscription, "next/2")
    :ok = demand(subscription, 1)
    monitor = Process.monitor(subscription.pid)

    try do
      receive do
        {:snodo_subscription, ^ref, payload} ->
          payload

        {:DOWN, ^monitor, :process, _pid, reason} ->
          {:closed,
           {:error, Transport.connection_error("The subscription process exited", reason)}}
      after
        timeout -> {:error, :timeout}
      end
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  @doc """
  The stream's payloads as an `Enumerable`, ending with `{:closed, reason}`.

  Each element is fetched with `next/2`, so the stream runs in the owner.
  Stopping early leaves the subscription open; call `close/1`.
  """
  @spec stream(t()) :: Enumerable.t()
  def stream(%__MODULE__{} = subscription) do
    Stream.resource(
      fn -> :open end,
      fn
        :open ->
          case next(subscription, :infinity) do
            {:closed, _reason} = closed -> {[closed], :done}
            payload -> {[payload], :open}
          end

        :done ->
          {:halt, :done}
      end,
      fn _state -> :ok end
    )
  end

  @doc """
  Ends the stream.

  The server is sent a cancellation: stdio writes `notifications/cancelled`,
  HTTP closes the connection, and the direct client closes the source. Returns
  `:ok`, also for a stream that has already ended.
  """
  @spec close(t()) :: :ok
  def close(%__MODULE__{pid: pid, ref: ref}) do
    GenServer.call(pid, {:mcp_client_close, ref}, @close_timeout)
  catch
    :exit, _reason -> :ok
  end

  defp owner!(%__MODULE__{owner: owner}, name) do
    if self() != owner do
      raise ArgumentError,
            "Snodo.Client.Subscription.#{name} must be called by the owner, #{inspect(owner)}"
    end
  end
end
