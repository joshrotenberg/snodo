defmodule Snodo.Logging do
  @moduledoc """
  Log messages from a request handler to the client, as `notifications/message`.

      :ok = Snodo.Logging.log(context, :info, "Import started", logger: "importer")
      :ok = Snodo.Logging.log(context, :debug, %{"rows" => 120})

  The server opts in by advertising the `"logging"` capability. Which messages
  reach the client then depends on the protocol revision:

    * 2026-07-28: the client sets `io.modelcontextprotocol/logLevel` in a
      request's `_meta`. Messages below that level are dropped, and a request
      without a level gets no messages at all.
    * 2025-11-25 and 2025-06-18: the client sets a level with
      `logging/setLevel`. Over stdio that level holds for the connection. Over
      HTTP these dialects keep no session, so a request uses the runtime's
      `:log_level` (default `:info`), which the older specifications allow
      when the client has not set one.

  `log/4` returns `:ok` both when the message was written and when it was
  dropped on purpose (no `"logging"` capability, below the level, no level, or
  no channel for notifications), so a handler can match `:ok`. It returns
  `{:error, reason}` for invalid input (`:invalid_level`, `:invalid_data`,
  `:invalid_logger`, `:too_large`) or when the request can no longer take
  messages (`:closed`, `:cancelled`, `:limit_reached`, `:timeout`,
  `:wrong_process`).

  Messages share the request's notification channel with progress
  notifications: they are written before the request's result, one at a time,
  each acknowledged after the transport writes it. A request may send at most
  1,000 messages, each with at most 16 KiB of encoded `data`. Only the process
  that runs the request may log; `Snodo.Component.Wrap.Timeout` hands that
  right to its task.
  """

  alias Snodo.Context
  alias Snodo.JSONValue
  alias Snodo.Progress

  @levels [:debug, :info, :notice, :warning, :error, :critical, :alert, :emergency]
  @level_names Map.new(@levels, &{Atom.to_string(&1), &1})
  @max_data_bytes 16_384

  @enforce_keys [:sink, :producer, :level, :context]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{
            sink: Snodo.Progress.Sink.t(),
            producer: pid(),
            level: level(),
            context: Context.t()
          }

  @type level ::
          :debug | :info | :notice | :warning | :error | :critical | :alert | :emergency

  @doc "The levels, from least to most severe (RFC 5424 severities)."
  @spec levels() :: [level()]
  def levels, do: @levels

  @doc """
  Sends `data` at `level` for the request in `context`.

  `data` is any JSON value. `opts` takes `:logger`, a string naming the
  source of the message.
  """
  @spec log(Context.t(), level(), term(), keyword()) :: :ok | {:error, atom()}
  def log(context, level, data, opts \\ [])

  def log(%Context{logging: binding}, level, data, opts) when is_list(opts) do
    with :ok <- valid_level(level),
         {:ok, fields} <- fields(level, data, opts) do
      deliver(binding, level, fields)
    end
  end

  @doc false
  # Parses a protocol level name; nil for anything else.
  @spec parse_level(term()) :: level() | nil
  def parse_level(name) when is_binary(name), do: Map.get(@level_names, name)
  def parse_level(name) when name in @levels, do: name
  def parse_level(_name), do: nil

  @doc false
  # Called by a dialect while it builds the request context. Without a sink or
  # a level there is nothing to send, so the context carries no binding.
  @spec bind(term(), Context.t(), level() | nil) :: t() | nil
  def bind(%Progress.Sink{} = sink, %Context{request_id: id} = context, level)
      when not is_nil(id) and level in @levels do
    %__MODULE__{sink: sink, producer: self(), level: level, context: %{context | logging: nil}}
  end

  def bind(_sink, %Context{}, _level), do: nil

  @doc false
  # Called by Snodo.Progress.accept/3 in the transport owner.
  @spec notification(map()) :: {:ok, map()} | {:error, atom()}
  def notification(%{"level" => level, "data" => _data} = fields) when is_binary(level) do
    known? = Map.keys(fields) -- ["level", "data", "logger"] == []

    if Map.has_key?(@level_names, level) and known?,
      do: {:ok, %{"jsonrpc" => "2.0", "method" => "notifications/message", "params" => fields}},
      else: {:error, :invalid_log}
  end

  def notification(_fields), do: {:error, :invalid_log}

  defp valid_level(level) when level in @levels, do: :ok
  defp valid_level(_level), do: {:error, :invalid_level}

  defp fields(level, data, opts) do
    with :ok <- known_options(opts),
         {:ok, logger} <- logger(Keyword.get(opts, :logger)),
         :ok <- valid_data(data) do
      fields = %{"level" => Atom.to_string(level), "data" => data}
      {:ok, if(logger, do: Map.put(fields, "logger", logger), else: fields)}
    end
  end

  defp known_options(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:logger] == [],
      do: :ok,
      else: {:error, :invalid_logger}
  end

  defp logger(nil), do: {:ok, nil}

  defp logger(name) when is_binary(name) do
    if String.valid?(name), do: {:ok, name}, else: {:error, :invalid_logger}
  end

  defp logger(_name), do: {:error, :invalid_logger}

  defp valid_data(data) do
    cond do
      not JSONValue.valid?(data) -> {:error, :invalid_data}
      byte_size(JSON.encode!(data)) > @max_data_bytes -> {:error, :too_large}
      true -> :ok
    end
  end

  defp deliver(nil, _level, _fields), do: :ok

  defp deliver(%__MODULE__{level: minimum} = binding, level, fields) do
    if severity(level) >= severity(minimum),
      do: Progress.submit(binding, fields),
      else: :ok
  end

  defp severity(level), do: Enum.find_index(@levels, &(&1 == level))
end
