defmodule Snodo.OTP.Contract do
  @moduledoc """
  One module describes a GenServer's remote-callable operations for both
  sides. The server side (`Snodo.OTP.Server.expose/2`) turns it into
  `Snodo.Tool.GenServer` declarations: JSON in, Elixir message, reply term,
  JSON out. The client side (`Snodo.OTP.Proxy`) uses the inverse pair:
  Elixir message in, JSON out over the wire, JSON reply back to a term.

  Nothing is inferred. An operation exists because the contract names it,
  with its schema, which keeps the boundary the GenServer tool experiment
  settled on: a client never chooses a process, atom or term.

  ## Declaring operations

  `use Snodo.OTP.Contract` declares each operation once with `call/2` or
  `cast/2` and generates every callback of the behaviour from it:

      defmodule CounterContract do
        use Snodo.OTP.Contract

        @by %{
          "type" => "object",
          "properties" => %{"by" => %{"type" => "integer"}},
          "required" => ["by"]
        }
        @value %{
          "type" => "object",
          "properties" => %{"value" => %{"type" => "integer"}},
          "required" => ["value"]
        }

        call("counter_add",
          message: {:add, {:arg, "by"}},
          reply: "value",
          input_schema: @by,
          output_schema: @value
        )

        cast("counter_cast_add", message: {:add, {:arg, "by"}}, input_schema: @by)
      end

  `:message` is the GenServer message as data. Atoms, numbers, strings,
  tuples, lists and maps are literal, and `{:arg, key}` marks the JSON
  argument `key`. The server builds the message by putting each argument in
  its place; the client matches a message against the same shape and sends
  the arguments it binds. A message that matches no operation gets
  `:nomatch`. Operations are tried in declaration order, so a more specific
  shape goes before a more general one.

  `:reply` (calls only) names the key of the JSON object that carries the
  reply term: the server sends `%{key => reply}` and the client returns the
  value under `key`.

  The other options are those of `t:op/0`: `:input_schema` (required),
  `:output_schema`, `:description` and `:timeout`.

  Compilation fails on a duplicate operation name, a missing `:message`, a
  call without `:reply` or a cast with one, and an argument the input
  schema's `properties` do not list.

  ## Sharing a contract

  The server node and the client node use the same compiled module, for
  example from a package or path dependency both depend on. A contract has
  no serialized form.

  ## Hand-written contracts

  A module can instead implement the callbacks below itself, for messages a
  `:message` shape cannot describe. A contract uses one form or the other.
  """

  @type op :: %{
          required(:name) => String.t(),
          required(:kind) => :call | :cast,
          required(:input_schema) => map(),
          optional(:output_schema) => map(),
          optional(:description) => String.t(),
          optional(:timeout) => pos_integer()
        }

  @doc "The operations, in catalog order."
  @callback ops() :: [op()]

  @doc "Server side: validated JSON arguments to the GenServer message."
  @callback build_message(name :: String.t(), args :: map()) :: term()

  @doc "Server side: the GenServer reply to a JSON object."
  @callback encode_reply(name :: String.t(), reply :: term()) :: map()

  @doc "Client side: a GenServer.call message to an operation and JSON arguments, or :nomatch."
  @callback encode_call(message :: term()) :: {String.t(), map()} | :nomatch

  @doc "Client side: a GenServer.cast message to an operation and JSON arguments, or :nomatch."
  @callback encode_cast(message :: term()) :: {String.t(), map()} | :nomatch

  @doc "Client side: the JSON reply object back to the term the caller expects."
  @callback decode_reply(name :: String.t(), json :: map()) :: term()

  @op_keys [:input_schema, :output_schema, :description, :timeout]

  defmacro __using__(_opts) do
    quote do
      @behaviour Snodo.OTP.Contract
      import Snodo.OTP.Contract, only: [call: 2, cast: 2]
      Module.register_attribute(__MODULE__, :snodo_otp_ops, accumulate: true)
      @before_compile Snodo.OTP.Contract
    end
  end

  @doc "Declares a `GenServer.call` operation. See the module documentation."
  defmacro call(name, opts) do
    quote do
      @snodo_otp_ops Snodo.OTP.Contract.__op__(
                       __MODULE__,
                       :call,
                       unquote(name),
                       unquote(opts),
                       __ENV__
                     )
    end
  end

  @doc "Declares a `GenServer.cast` operation. See the module documentation."
  defmacro cast(name, opts) do
    quote do
      @snodo_otp_ops Snodo.OTP.Contract.__op__(
                       __MODULE__,
                       :cast,
                       unquote(name),
                       unquote(opts),
                       __ENV__
                     )
    end
  end

  @doc false
  def __op__(module, kind, name, opts, env) do
    case check(module, kind, name, opts) do
      :ok ->
        op = opts |> Keyword.take(@op_keys) |> Map.new() |> Map.merge(%{name: name, kind: kind})
        %{op: op, message: opts[:message], reply: opts[:reply]}

      {:error, message} ->
        raise CompileError, description: message, file: env.file, line: env.line
    end
  end

  defp check(module, kind, name, opts) do
    cond do
      not is_binary(name) ->
        {:error, "operation name must be a string, got: #{inspect(name)}"}

      Enum.any?(Module.get_attribute(module, :snodo_otp_ops), &(&1.op.name == name)) ->
        {:error, "duplicate operation #{inspect(name)}"}

      is_nil(opts[:message]) ->
        {:error, "operation #{inspect(name)} needs :message"}

      is_nil(opts[:input_schema]) ->
        {:error, "operation #{inspect(name)} needs :input_schema"}

      true ->
        with :ok <- check_reply(kind, name, opts[:reply]),
             do: check_args(name, opts[:message], opts[:input_schema])
    end
  end

  defp check_reply(:call, _name, key) when is_binary(key), do: :ok
  defp check_reply(:cast, _name, nil), do: :ok

  defp check_reply(:call, name, _key),
    do: {:error, "call #{inspect(name)} needs :reply, the string key of its reply"}

  defp check_reply(:cast, name, _key),
    do: {:error, "cast #{inspect(name)} has no reply; remove :reply"}

  defp check_args(name, message, schema) do
    case unknown_args(message, schema) do
      [] ->
        :ok

      keys ->
        {:error,
         "operation #{inspect(name)} uses arguments not in its input schema: #{inspect(keys)}"}
    end
  end

  defp unknown_args(message, %{"properties" => properties}) when is_map(properties),
    do: message |> args() |> Enum.reject(&Map.has_key?(properties, &1)) |> Enum.uniq()

  defp unknown_args(_message, _schema), do: []

  defp args({:arg, key}), do: [key]
  defp args(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> args()
  defp args(list) when is_list(list), do: Enum.flat_map(list, &args/1)
  defp args(%{} = map), do: map |> Map.values() |> args()
  defp args(_literal), do: []

  defmacro __before_compile__(env) do
    decls = env.module |> Module.get_attribute(:snodo_otp_ops) |> Enum.reverse()

    if decls == [] do
      quote do: :ok
    else
      generate(decls)
    end
  end

  defp generate(decls) do
    ops = Enum.map(decls, & &1.op)
    calls = Enum.filter(decls, &(&1.op.kind == :call))
    casts = Enum.filter(decls, &(&1.op.kind == :cast))
    args = Macro.var(:args, __MODULE__)
    reply = Macro.var(:reply, __MODULE__)

    quote do
      @impl true
      def ops, do: unquote(Macro.escape(ops))

      @impl true
      unquote_splicing(
        for %{op: %{name: name}, message: message} <- decls do
          # A message without arguments leaves the variable unused.
          var = if args(message) == [], do: Macro.var(:_args, __MODULE__), else: args

          quote do
            def build_message(unquote(name), unquote(var)), do: unquote(build(message, args))
          end
        end
      )

      @impl true
      unquote_splicing(encoders(:encode_call, calls))

      @impl true
      unquote_splicing(encoders(:encode_cast, casts))

      @impl true
      unquote_splicing(
        for %{op: %{name: name}, reply: key} <- calls do
          quote do
            def encode_reply(unquote(name), unquote(reply)), do: %{unquote(key) => unquote(reply)}
          end
        end
      )

      def encode_reply(name, _reply),
        do: raise(ArgumentError, "no call operation named #{inspect(name)}")

      @impl true
      unquote_splicing(
        for %{op: %{name: name}, reply: key} <- calls do
          quote do
            def decode_reply(unquote(name), %{unquote(key) => unquote(reply)}), do: unquote(reply)
          end
        end
      )

      def decode_reply(name, json),
        do: raise(ArgumentError, "cannot decode #{inspect(json)} for #{inspect(name)}")
    end
  end

  defp encoders(fun, decls) do
    clauses =
      for %{op: %{name: name}, message: message} <- decls do
        bound =
          message |> args() |> Enum.uniq() |> Map.new(&{&1, Macro.var(var_name(&1), __MODULE__)})

        quote do
          def unquote(fun)(unquote(pattern(message, bound))),
            do: {unquote(name), %{unquote_splicing(Map.to_list(bound))}}
        end
      end

    clauses ++ [quote(do: def(unquote(fun)(_message), do: :nomatch))]
  end

  # The message as an expression, with each argument read from `args`.
  defp build({:arg, key}, args), do: quote(do: Map.get(unquote(args), unquote(key)))

  defp build(tuple, args) when is_tuple(tuple),
    do: {:{}, [], tuple |> Tuple.to_list() |> Enum.map(&build(&1, args))}

  defp build(list, args) when is_list(list), do: Enum.map(list, &build(&1, args))

  defp build(%{} = map, args),
    do: {:%{}, [], Enum.map(map, fn {k, v} -> {Macro.escape(k), build(v, args)} end)}

  defp build(literal, _args), do: Macro.escape(literal)

  # The message as a pattern, with each argument bound to its variable.
  defp pattern({:arg, key}, bound), do: Map.fetch!(bound, key)

  defp pattern(tuple, bound) when is_tuple(tuple),
    do: {:{}, [], tuple |> Tuple.to_list() |> Enum.map(&pattern(&1, bound))}

  defp pattern(list, bound) when is_list(list), do: Enum.map(list, &pattern(&1, bound))

  defp pattern(%{} = map, bound),
    do: {:%{}, [], Enum.map(map, fn {k, v} -> {Macro.escape(k), pattern(v, bound)} end)}

  defp pattern(literal, _bound), do: Macro.escape(literal)

  defp var_name(key), do: String.to_atom("arg_" <> to_string(key))
end
