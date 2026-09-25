defmodule Snodo.Prompt.Simple do
  @moduledoc """
  `Snodo.Prompt` with declared arguments and plain return values from `render/2`.

  Arguments are declared one per line instead of as a list of maps:

      defmodule Review do
        use Snodo.Prompt.Simple, name: "review", description: "Review a package"

        argument "name", required: true, description: "Package name on hex.pm"
        argument "focus", description: "quality, security, or upgrade"

        @impl true
        def render(%{"name" => name} = arguments, _context) do
          {:ok, "Review \#{name}, focusing on \#{arguments["focus"] || "quality"}."}
        end
      end

  `argument/2` accepts `:required`, `:description`, and `:title`. The module
  accepts every other `Snodo.Prompt` option (`:name`, `:title`, `:description`,
  `:completion_arguments`, `:icons`, `:metadata`) and its definition is
  validated at compile time by the same checks `use Snodo.Prompt` runs.

  `render/2` may return:

    * `{:ok, text}` with a binary: one user message containing that text.
    * `{:ok, message}` or `{:ok, [message]}`: messages built with
      `Snodo.Prompt.message/2`, validated by the router as usual.
    * `{:ok, %Snodo.Result{}}` and `{:error, reason}`, unchanged. Use
      `Snodo.Result.prompt_get/2` for a description or metadata and
      `Snodo.Result.input_required/1` for MRTR.
  """

  alias Snodo.Prompt
  alias Snodo.Result

  @options [:name, :title, :description, :completion_arguments, :icons, :metadata]
  @argument_options [:required, :description, :title]
  @argument_keys %{required: "required", description: "description", title: "title"}

  defmacro __using__(opts) do
    quote do
      @behaviour Snodo.Prompt

      import Snodo.Prompt.Simple, only: [argument: 1, argument: 2]

      Module.register_attribute(__MODULE__, :mcp_prompt_simple_arguments, accumulate: true)

      @mcp_prompt_simple_options Snodo.Prompt.Simple.validate_options!(
                                   unquote(opts),
                                   __ENV__
                                 )

      @before_compile Snodo.Prompt.Simple
    end
  end

  @doc "Declares one prompt argument. Arguments are listed in declaration order."
  defmacro argument(name, opts \\ []) do
    quote do
      @mcp_prompt_simple_arguments Snodo.Prompt.Simple.argument!(
                                     unquote(name),
                                     unquote(opts),
                                     __ENV__
                                   )
    end
  end

  defmacro __before_compile__(env) do
    options = Module.get_attribute(env.module, :mcp_prompt_simple_options)

    arguments =
      env.module
      |> Module.get_attribute(:mcp_prompt_simple_arguments)
      |> Enum.reverse()

    definition = Prompt.compile_definition!(env, Keyword.put(options, :arguments, arguments))

    unless Module.defines?(env.module, {:render, 2}, :def) do
      compile_error!(
        env,
        "#{inspect(env.module)} uses Snodo.Prompt.Simple but does not define render/2"
      )
    end

    quote do
      @impl Snodo.Prompt
      def definition, do: unquote(Macro.escape(definition))

      defoverridable render: 2

      @impl Snodo.Prompt
      def render(arguments, context) do
        Snodo.Prompt.Simple.normalize(super(arguments, context))
      end
    end
  end

  @doc false
  @spec validate_options!(term(), Macro.Env.t()) :: keyword()
  def validate_options!(opts, env) do
    unless Keyword.keyword?(opts) do
      compile_error!(env, "Snodo.Prompt.Simple options must be a keyword list")
    end

    if Keyword.has_key?(opts, :arguments) do
      compile_error!(
        env,
        "Snodo.Prompt.Simple declares arguments with argument/2, not :arguments"
      )
    end

    case opts |> Keyword.keys() |> Enum.reject(&(&1 in @options)) |> Enum.uniq() do
      [] ->
        opts

      unknown ->
        compile_error!(env, "Snodo.Prompt.Simple received unknown options: #{inspect(unknown)}")
    end
  end

  @doc false
  @spec argument!(term(), term(), Macro.Env.t()) :: map()
  def argument!(name, opts, env) when is_binary(name) and name != "" do
    unless Keyword.keyword?(opts) do
      compile_error!(env, "prompt argument #{inspect(name)} options must be a keyword list")
    end

    case opts |> Keyword.keys() |> Enum.reject(&(&1 in @argument_options)) |> Enum.uniq() do
      [] ->
        :ok

      unknown ->
        compile_error!(
          env,
          "prompt argument #{inspect(name)} received unknown options: #{inspect(unknown)}"
        )
    end

    Enum.reduce(opts, %{"name" => name}, fn {option, value}, argument ->
      Map.put(argument, Map.fetch!(@argument_keys, option), value)
    end)
  end

  def argument!(name, _opts, env) do
    compile_error!(env, "prompt argument names must be non-empty strings, got: #{inspect(name)}")
  end

  @doc false
  @spec normalize(term()) :: term()
  def normalize({:ok, %Result{}} = result), do: result

  def normalize({:ok, text}) when is_binary(text) do
    {:ok, Result.prompt_get(Prompt.message(:user, Prompt.text(text)))}
  end

  def normalize({:ok, messages}) when is_list(messages) or is_map(messages) do
    {:ok, Result.prompt_get(messages)}
  end

  def normalize(other), do: other

  @spec compile_error!(Macro.Env.t(), String.t()) :: no_return()
  defp compile_error!(env, description) do
    raise CompileError, file: env.file, line: env.line, description: description
  end
end
