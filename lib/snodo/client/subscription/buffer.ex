defmodule Snodo.Client.Subscription.Buffer do
  @moduledoc false
  # The bounded queue behind one `Snodo.Client.Subscription`, kept by the
  # transport process that receives the stream. An event is sent to the owner
  # while the owner has demand and queued otherwise. A full queue discards an
  # event by the overflow policy and counts it; the count reaches the owner
  # as `{:dropped, n}` before the next delivered event. The terminal
  # `{:closed, reason}` waits behind the queued events, so the owner sees
  # every event it asks for before the end of the stream.

  @enforce_keys [:owner, :ref, :max_buffer, :overflow]
  defstruct [
    :owner,
    :ref,
    :max_buffer,
    :overflow,
    queue: :queue.new(),
    size: 0,
    demand: 0,
    dropped: 0,
    closed: nil
  ]

  @type t :: %__MODULE__{
          owner: pid(),
          ref: reference(),
          max_buffer: pos_integer(),
          overflow: :drop_oldest | :drop_newest,
          queue: :queue.queue(),
          size: non_neg_integer(),
          demand: non_neg_integer(),
          dropped: non_neg_integer(),
          closed: nil | {:pending, term()} | {:delivered, term()}
        }

  @doc false
  @spec new(pid(), reference(), keyword()) :: t()
  def new(owner, ref, opts) when is_pid(owner) and is_reference(ref) do
    %__MODULE__{
      owner: owner,
      ref: ref,
      max_buffer: Keyword.fetch!(opts, :max_buffer),
      overflow: Keyword.fetch!(opts, :overflow)
    }
  end

  @doc false
  @spec push(t(), {:notification, String.t(), map()}) :: t()
  def push(%__MODULE__{closed: nil, demand: demand} = buffer, payload) when demand > 0 do
    buffer |> flush_dropped() |> deliver(payload) |> Map.put(:demand, demand - 1)
  end

  def push(%__MODULE__{closed: nil} = buffer, payload), do: enqueue(buffer, payload)

  # Nothing follows the terminal response.
  def push(%__MODULE__{} = buffer, _payload), do: buffer

  @doc false
  @spec demand(t(), pos_integer()) :: t()
  def demand(%__MODULE__{demand: demand} = buffer, n) when is_integer(n) and n > 0 do
    drain(%{buffer | demand: demand + n})
  end

  @doc "Ends the stream after the queued events have been delivered."
  @spec close(t(), term()) :: t()
  def close(%__MODULE__{closed: nil} = buffer, reason),
    do: maybe_finish(%{buffer | closed: {:pending, reason}})

  def close(%__MODULE__{} = buffer, _reason), do: buffer

  @doc "Ends the stream now, discarding queued events."
  @spec abort(t(), term()) :: t()
  def abort(%__MODULE__{closed: {:delivered, _delivered}} = buffer, _reason), do: buffer

  def abort(%__MODULE__{} = buffer, reason) do
    buffer
    |> Map.merge(%{queue: :queue.new(), size: 0, dropped: 0})
    |> deliver({:closed, reason})
    |> Map.put(:closed, {:delivered, reason})
  end

  @doc false
  @spec done?(t()) :: boolean()
  def done?(%__MODULE__{closed: {:delivered, _reason}}), do: true
  def done?(%__MODULE__{}), do: false

  @doc false
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{closed: nil}), do: false
  def terminal?(%__MODULE__{}), do: true

  defp enqueue(%__MODULE__{size: size, max_buffer: max} = buffer, payload) when size < max do
    %{buffer | queue: :queue.in(payload, buffer.queue), size: size + 1}
  end

  defp enqueue(%__MODULE__{overflow: :drop_oldest} = buffer, payload) do
    {{:value, _oldest}, queue} = :queue.out(buffer.queue)
    %{buffer | queue: :queue.in(payload, queue), dropped: buffer.dropped + 1}
  end

  defp enqueue(%__MODULE__{overflow: :drop_newest} = buffer, _payload) do
    %{buffer | dropped: buffer.dropped + 1}
  end

  defp drain(%__MODULE__{demand: demand, size: size} = buffer) when demand > 0 and size > 0 do
    {{:value, payload}, queue} = :queue.out(buffer.queue)

    %{buffer | queue: queue, size: size - 1, demand: demand - 1}
    |> flush_dropped()
    |> deliver(payload)
    |> drain()
  end

  defp drain(buffer), do: maybe_finish(buffer)

  defp maybe_finish(%__MODULE__{closed: {:pending, reason}, size: 0} = buffer) do
    buffer
    |> flush_dropped()
    |> deliver({:closed, reason})
    |> Map.put(:closed, {:delivered, reason})
  end

  defp maybe_finish(buffer), do: buffer

  defp flush_dropped(%__MODULE__{dropped: 0} = buffer), do: buffer

  defp flush_dropped(%__MODULE__{dropped: dropped} = buffer) do
    %{buffer | dropped: 0} |> deliver({:dropped, dropped})
  end

  defp deliver(%__MODULE__{owner: owner, ref: ref} = buffer, payload) do
    send(owner, {:snodo_subscription, ref, payload})
    buffer
  end
end
