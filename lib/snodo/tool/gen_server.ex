defmodule Snodo.Tool.GenServer do
  @moduledoc """
  Generates MCP tools for explicitly declared GenServer calls and casts.

  Import `genserver_call/2` and `genserver_cast/2` into a `Snodo.Server` module.
  Each declaration generates an ordinary `Snodo.Tool` module and registers it
  through the server DSL. The target is a fixed, registered module name; MCP
  clients cannot choose a process, message, or Elixir term.

      defmodule CounterServer do
        use Snodo.Server, name: "counter", version: "1.0.0"
        import Snodo.Tool.GenServer

        genserver_call "counter_get",
          target: Counter,
          input_schema: %{"type" => "object", "additionalProperties" => false},
          message: :get,
          encode_reply: fn count -> %{"value" => count} end
      end

  `:message` may be a fixed term or a one-argument function receiving the
  validated string-keyed input map. Calls require `:encode_reply`, a one-argument
  function that returns a JSON object. `:timeout` defaults to 5,000 milliseconds
  and must be a positive integer. Failed validation, message construction,
  unavailable targets, timeouts, and non-JSON replies become tool error results.

  Input schemas may use the assertions enforced by
  `Snodo.Schema.Validator.Basic` and the annotations `title`, `description`,
  `default`, and `x-mcp-header`. Unsupported keywords fail compilation so a
  declaration cannot advertise a constraint that this adapter ignores.

  A cast result means only that `GenServer.cast/2` accepted the message for
  sending. An absent target is reported as a tool error, but the target can
  stop after the availability check. A successful cast does not establish
  that the target received or processed it.
  """

  alias Snodo.JSONValue
  alias Snodo.Result
  alias Snodo.Schema.Validator.Basic

  @default_timeout 5_000
  @call_options [
    :target,
    :input_schema,
    :message,
    :encode_reply,
    :description,
    :output_schema,
    :timeout
  ]
  @cast_options [:target, :input_schema, :message, :description]
  @validated_schema_keywords ~w(
    type const enum required properties additionalProperties items
    minProperties maxProperties minItems maxItems uniqueItems minLength maxLength
    pattern minimum maximum exclusiveMinimum exclusiveMaximum
    title description default x-mcp-header
  )

  @doc "Defines and registers a tool that sends a bounded `GenServer.call/3`."
  defmacro genserver_call(name, opts) do
    generate(__CALLER__, :call, name, opts)
  end

  @doc "Defines and registers a tool that sends `GenServer.cast/2`."
  defmacro genserver_cast(name, opts) do
    generate(__CALLER__, :cast, name, opts)
  end

  defp generate(env, kind, name, opts) do
    validate_options!(env, kind, name, opts)
    target = fixed_target!(env, Keyword.fetch!(opts, :target))
    module = claim_module!(env, name)
    schema = Keyword.fetch!(opts, :input_schema)
    message = Keyword.fetch!(opts, :message)
    description = Keyword.get(opts, :description)
    body = generated_body(kind, target, message, opts)

    quote do
      defmodule unquote(module) do
        @moduledoc false
        use Snodo.Tool, name: unquote(name), description: unquote(description)
        input_schema(unquote(schema))
        Snodo.Tool.GenServer.validate_schema!(@mcp_tool_input_schema, __ENV__)
        unquote(body)
      end

      tool(unquote(module))
    end
  end

  defp fixed_target!(env, target_ast) do
    target = Macro.expand(target_ast, env)

    if is_atom(target) and not is_nil(target),
      do: target,
      else:
        raise(CompileError,
          file: env.file,
          line: env.line,
          description: ":target must be a fixed module name"
        )
  end

  defp claim_module!(env, name) do
    module =
      Module.concat([
        env.module,
        GenServerTools,
        name |> String.replace(~r/[^A-Za-z0-9]+/, "_") |> Macro.camelize()
      ])

    claimed = Module.get_attribute(env.module, :snodo_genserver_tools) || []

    if Enum.any?(claimed, fn {other_module, other_name} ->
         other_module == module or other_name == name
       end) do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "GenServer tool #{inspect(name)} duplicates an earlier declaration"
    end

    Module.put_attribute(env.module, :snodo_genserver_tools, [{module, name} | claimed])
    module
  end

  defp generated_body(:call, target, message, opts) do
    encoder = Keyword.fetch!(opts, :encode_reply)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    output_schema = Keyword.get(opts, :output_schema)

    quote do
      output_schema(unquote(output_schema))

      @impl Snodo.Tool
      def call(arguments, _context) do
        Snodo.Tool.GenServer.invoke_call(
          unquote(target),
          unquote(message),
          unquote(encoder),
          unquote(timeout),
          input_schema(),
          arguments
        )
      end
    end
  end

  defp generated_body(:cast, target, message, _opts) do
    quote do
      @impl Snodo.Tool
      def call(arguments, _context) do
        Snodo.Tool.GenServer.invoke_cast(
          unquote(target),
          unquote(message),
          input_schema(),
          arguments
        )
      end
    end
  end

  defp validate_options!(env, kind, name, opts) do
    validate_name!(env, name)
    allowed = if kind == :call, do: @call_options, else: @cast_options

    required =
      if kind == :call,
        do: [:target, :input_schema, :message, :encode_reply],
        else: [:target, :input_schema, :message]

    validate_keys!(env, kind, name, opts, allowed, required)
    if kind == :call, do: validate_timeout!(env, opts)
  end

  defp validate_name!(env, name) do
    unless is_binary(name) and name != "" do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "GenServer tool names must be non-empty string literals"
    end
  end

  defp validate_keys!(env, kind, name, opts, allowed, required) do
    unless Keyword.keyword?(opts) and Keyword.keys(opts) -- allowed == [] and
             Enum.all?(required, &Keyword.has_key?(opts, &1)) do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "GenServer #{kind} #{inspect(name)} has missing or unknown options"
    end
  end

  defp validate_timeout!(env, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    unless is_integer(timeout) and timeout > 0 do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: ":timeout must be a positive integer"
    end
  end

  @doc false
  def validate_schema!(schema, env) do
    case unsupported_schema_keyword(schema, []) do
      nil ->
        :ok

      {path, keyword} ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description:
            "GenServer tool input schema uses unsupported keyword " <>
              inspect(keyword) <> " at " <> inspect(path)
    end
  end

  defp unsupported_schema_keyword(schema, path) when is_map(schema) do
    unknown = Enum.find(Map.keys(schema), &(&1 not in @validated_schema_keywords))

    if unknown do
      {path, unknown}
    else
      nested_schema_keyword(schema, path)
    end
  end

  defp unsupported_schema_keyword(schema, _path) when is_boolean(schema), do: nil
  defp unsupported_schema_keyword(_schema, path), do: {path, "invalid schema"}

  defp nested_schema_keyword(schema, path) do
    properties =
      case Map.get(schema, "properties", %{}) do
        children when is_map(children) ->
          Enum.find_value(children, fn {name, child} ->
            unsupported_schema_keyword(child, path ++ [name])
          end)

        _invalid ->
          {path ++ ["properties"], "invalid schema"}
      end

    properties ||
      Enum.find_value(["items", "additionalProperties"], fn keyword ->
        case Map.fetch(schema, keyword) do
          {:ok, child} -> unsupported_schema_keyword(child, path ++ [keyword])
          :error -> nil
        end
      end)
  end

  @doc false
  def invoke_call(target, message, encoder, timeout, schema, arguments) do
    with :ok <- validate_arguments(arguments, schema),
         {:ok, built} <- build_message(message, arguments),
         {:ok, reply} <- safe_call(target, built, timeout) do
      encode_reply(encoder, reply)
    else
      {:error, result} -> {:ok, result}
    end
  end

  @doc false
  def invoke_cast(target, message, schema, arguments) do
    with :ok <- validate_arguments(arguments, schema),
         {:ok, built} <- build_message(message, arguments),
         :ok <- available_target(target) do
      :ok = GenServer.cast(target, built)
      {:ok, Result.structured(%{"sent" => true})}
    else
      {:error, result} -> {:ok, result}
    end
  end

  defp available_target(target) do
    if Process.whereis(target),
      do: :ok,
      else: {:error, Result.error("GenServer target unavailable")}
  end

  defp validate_arguments(arguments, schema) do
    if JSONValue.valid?(arguments) and json_encodable?(arguments) do
      case Basic.validate(arguments, schema) do
        :ok -> :ok
        {:error, error} -> {:error, Result.error("Invalid tool arguments: #{error.message}")}
      end
    else
      {:error, Result.error("Tool arguments must be JSON values with string keys")}
    end
  end

  defp build_message(builder, arguments) do
    {:ok, if(is_function(builder, 1), do: builder.(arguments), else: builder)}
  rescue
    _error -> {:error, Result.error("Could not build GenServer message")}
  catch
    _kind, _reason -> {:error, Result.error("Could not build GenServer message")}
  end

  defp safe_call(target, message, timeout) do
    {:ok, GenServer.call(target, message, timeout)}
  catch
    :exit, {:timeout, _details} -> {:error, Result.error("GenServer call timed out")}
    :exit, {:noproc, _details} -> {:error, Result.error("GenServer target unavailable")}
    :exit, _reason -> {:error, Result.error("GenServer call failed")}
  end

  defp encode_reply(encoder, reply) when is_function(encoder, 1) do
    encoded = encoder.(reply)

    if is_map(encoded) and not is_struct(encoded) and JSONValue.valid?(encoded) and
         json_encodable?(encoded),
       do: {:ok, Result.structured(encoded)},
       else: {:ok, Result.error("GenServer reply is not a JSON object")}
  rescue
    _error -> {:ok, Result.error("Could not encode GenServer reply")}
  catch
    _kind, _reason -> {:ok, Result.error("Could not encode GenServer reply")}
  end

  defp encode_reply(_encoder, _reply),
    do: {:ok, Result.error("GenServer reply encoder is invalid")}

  defp json_encodable?(value) do
    _json = JSON.encode!(value)
    true
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end
end
