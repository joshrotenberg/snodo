defmodule Snodo.Component.Wrap do
  @moduledoc """
  Opt-in middleware for one tool, resource, or prompt callback.

  A component declares `wrap: [MyWrapper, {AnotherWrapper, option: value}]`.
  Each wrapper implements `call/4`. The first declared wrapper runs first and
  receives a continuation that calls the next wrapper with a context and
  arguments. A wrapper may call that continuation, replace the context or
  arguments, or return a result without invoking the handler.

  The options passed to `call/4` include the declaration's options plus
  `:component`, `:kind`, `:operation`, and `:slot`. Those keys identify the
  component and wrapper occurrence. Resource and prompt wrappers also run on
  an explicitly defined `complete/2` callback. Middleware runs inside the
  component callback, after router lookup, authorization, and input validation.
  """

  alias Snodo.Context

  @type kind :: :tool | :resource | :prompt
  @type continuation :: (Context.t(), term() -> term())

  @reserved_options [:component, :kind, :operation, :slot]

  @doc "Runs one middleware layer and may call the continuation or return a result."
  @callback call(Context.t(), term(), continuation(), keyword()) :: term()

  @doc false
  def validate_declaration!(ast, env) do
    unless static_ast?(ast) do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "wrap: expects literal values or module attributes, not runtime expressions"
    end

    :ok
  end

  @doc false
  def validate_specs!(specs, env) when is_list(specs) do
    Enum.each(specs, fn spec ->
      {module, options} = normalize_spec(spec)

      unless is_atom(module) and valid_options?(options) and
               match?({:module, ^module}, Code.ensure_compiled(module)) and
               function_exported?(module, :call, 4) do
        raise CompileError,
          file: env.file,
          line: env.line,
          description: "wrap: expects modules implementing call/4 and keyword options"
      end

      if function_exported?(module, :validate_options!, 2),
        do: module.validate_options!(options, env)
    end)

    :ok
  end

  def validate_specs!(_specs, env) do
    raise CompileError,
      file: env.file,
      line: env.line,
      description: "wrap: expects a list of wrapper modules or {module, options} tuples"
  end

  @doc false
  defmacro __before_compile__(env) do
    wrap_ast = Module.get_attribute(env.module, :snodo_component_wrap_ast) || []
    kind = Module.get_attribute(env.module, :snodo_component_wrap_kind)
    callback = %{tool: :call, resource: :read, prompt: :render} |> Map.fetch!(kind)

    if wrap_ast == [] do
      quote(do: :ok)
    else
      unless Module.defines?(env.module, {callback, 2}, :def) do
        raise CompileError,
          file: env.file,
          line: env.line,
          description: "wrapped #{kind} must define #{callback}/2"
      end

      completion = completion_ast(env, kind)

      quote do
        defoverridable [{unquote(callback), 2}]

        def unquote(callback)(arguments, context) do
          Snodo.Component.Wrap.invoke(
            __MODULE__,
            unquote(kind),
            unquote(callback),
            __snodo_component_wrap_specs__(),
            context,
            arguments,
            fn next_context, next_arguments -> super(next_arguments, next_context) end
          )
        end

        unquote(completion)
      end
    end
  end

  @doc false
  @spec invoke(module(), kind(), atom(), list(), Context.t(), term(), continuation()) :: term()
  def invoke(component, kind, operation, specs, context, arguments, handler) do
    specs
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.reduce(handler, fn {spec, slot}, next ->
      {module, options} = normalize_spec(spec)

      options =
        Keyword.merge(options,
          component: component,
          kind: kind,
          operation: operation,
          slot: slot
        )

      fn next_context, next_arguments ->
        module.call(next_context, next_arguments, next, options)
      end
    end)
    |> then(& &1.(context, arguments))
  end

  @doc false
  def reject(:tool, message), do: {:ok, Snodo.Result.error(message)}
  def reject(_kind, message), do: {:error, Snodo.Error.internal(message)}

  @doc false
  def key(context, options) do
    case Keyword.get(options, :key) do
      nil -> {:ok, :global}
      key_fn -> {:ok, key_fn.(context)}
    end
  rescue
    _error -> {:error, :key_failed}
  catch
    _kind, _reason -> {:error, :key_failed}
  end

  defp normalize_spec({module, options}), do: {module, options}
  defp normalize_spec(module), do: {module, []}

  defp completion_ast(env, kind) do
    if kind in [:resource, :prompt] and Module.defines?(env.module, {:complete, 2}, :def) do
      quote do
        defoverridable complete: 2

        def complete(arguments, context) do
          Snodo.Component.Wrap.invoke(
            __MODULE__,
            unquote(kind),
            :complete,
            __snodo_component_wrap_specs__(),
            context,
            arguments,
            fn next_context, next_arguments -> super(next_arguments, next_context) end
          )
        end
      end
    else
      quote(do: :ok)
    end
  end

  defp valid_options?(options) do
    Keyword.keyword?(options) and
      Enum.all?(Keyword.keys(options), &(&1 not in @reserved_options))
  end

  defp static_ast?(value) when is_atom(value) or is_number(value) or is_binary(value),
    do: true

  defp static_ast?(list) when is_list(list), do: Enum.all?(list, &static_ast?/1)
  defp static_ast?({:@, _, [_attribute]}), do: true
  defp static_ast?({:fn, _, _clauses}), do: true
  defp static_ast?({:&, _, _capture}), do: true
  defp static_ast?({:__MODULE__, _, _context}), do: true
  defp static_ast?({:__aliases__, _, parts}), do: Enum.all?(parts, &static_ast?/1)
  defp static_ast?({:{}, _, parts}), do: Enum.all?(parts, &static_ast?/1)

  defp static_ast?({:%{}, _, pairs}),
    do: Enum.all?(pairs, fn {key, value} -> static_ast?(key) and static_ast?(value) end)

  defp static_ast?({left, right}), do: static_ast?(left) and static_ast?(right)
  defp static_ast?(_other), do: false
end
