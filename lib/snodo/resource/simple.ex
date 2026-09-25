defmodule Snodo.Resource.Simple do
  @moduledoc """
  `Snodo.Resource` with plain return values from `read/2`.

  It accepts every `Snodo.Resource` option and produces the same definition and
  matcher. The difference is what `read/2` may return:

    * `{:ok, text}` with a binary is one text content at the requested URI,
      carrying the declared `:mime_type`.
    * `{:ok, value}` with any other JSON value is one JSON content, with
      `"application/json"` unless another `:mime_type` is declared.
    * `{:ok, %Snodo.Result{}}` and `{:error, reason}` pass through unchanged. Use
      `Snodo.Result.resource_read/2` for blobs, several contents, cache hints,
      or content metadata, and `Snodo.Result.input_required/1` for MRTR.

  JSON values must already use string keys; `Snodo.JSONValue.encodable!/1`
  converts an atom-keyed domain value.

      defmodule ToolboxGroups do
        use Snodo.Resource.Simple,
          uri: "toolbox://groups",
          name: "toolbox_groups",
          mime_type: "application/json"

        @impl true
        def read(_params, _context), do: {:ok, %{"groups" => ["web", "data"]}}
      end

  The conversion wraps the module's own `read/2`, so `Snodo.Router` receives an
  `Snodo.Result` exactly as it does from a plain `Snodo.Resource`.
  """

  alias Snodo.Resource
  alias Snodo.Resource.Definition
  alias Snodo.Result

  defmacro __using__(opts) do
    quote do
      use Snodo.Resource, unquote(opts)
      @before_compile Snodo.Resource.Simple
    end
  end

  defmacro __before_compile__(env) do
    unless Module.defines?(env.module, {:read, 2}, :def) do
      raise CompileError,
        file: env.file,
        line: env.line,
        description:
          "#{inspect(env.module)} uses Snodo.Resource.Simple but does not define read/2"
    end

    quote do
      defoverridable read: 2

      @impl Snodo.Resource
      def read(params, context) do
        Snodo.Resource.Simple.normalize(super(params, context), params, definition())
      end
    end
  end

  @doc false
  @spec normalize(term(), map(), Definition.t()) :: term()
  def normalize({:ok, %Result{}} = result, _params, _definition), do: result

  def normalize({:ok, text}, %{"uri" => uri}, %Definition{} = definition) when is_binary(text) do
    {:ok, Result.resource_read(Resource.text(uri, text, mime_type_option(definition)))}
  end

  def normalize({:ok, value}, %{"uri" => uri}, %Definition{} = definition) do
    {:ok, Result.resource_read(Resource.json(uri, value, mime_type_option(definition)))}
  end

  def normalize(other, _params, _definition), do: other

  defp mime_type_option(%Definition{mime_type: nil}), do: []
  defp mime_type_option(%Definition{mime_type: mime_type}), do: [mime_type: mime_type]
end
