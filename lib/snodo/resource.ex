defmodule Snodo.Resource do
  @moduledoc """
  Behaviour and compile-time convenience DSL for MCP resources.

  A resource module declares either one exact `:uri` or one `:uri_template`.
  URI routing stays application-owned: the framework does not implement RFC
  6570 expansion or authorization policy.

  A template inside the simple-expansion subset described in
  `Snodo.Resource.Template` gets a generated `matches?/1`, so the common
  `scheme://{var}/literal` shape needs no matcher at all. A template outside
  that subset matches nothing until the module implements `matches?/1` itself.

  `matches?/1` may answer in two ways. `true` and `false` route without saying
  anything more. `{:ok, variables}`, a map of string keys to string values,
  routes *and* hands the extracted template variables to `read/2`, so a
  matcher never has to be paired with a second parse of the same URI. The
  generated matcher uses this form. Variables may not shadow `"uri"` or
  `"_meta"`, which the request itself owns.

  `read/2` receives the request params, merged with any variables the matcher
  bound, plus the immutable request context. It returns
  `Snodo.Result.resource_read/2` containing text or blob content maps.

      defmodule PackageInfo do
        use Snodo.Resource, uri_template: "hex://{name}/info", name: "package_info"

        @impl true
        def read(%{"name" => name}, _context), do: fetch(name)
      end

  Content maps must contain only JSON values, which means string keys.
  `Snodo.JSONValue.encodable!/1` converts an atom-keyed domain value into one.
  """

  alias Snodo.Completion
  alias Snodo.Context
  alias Snodo.Error
  alias Snodo.JSONValue
  alias Snodo.Resource.Definition
  alias Snodo.Resource.Template
  alias Snodo.Result

  @meta_key ~r/^(?:(?:[A-Za-z](?:[A-Za-z0-9-]*[A-Za-z0-9])?)(?:\.(?:[A-Za-z](?:[A-Za-z0-9-]*[A-Za-z0-9])?))*\/)?(?:[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?)?$/

  @callback definition() :: Definition.t()
  @callback matches?(uri :: String.t()) :: boolean() | {:ok, Template.variables()}
  @callback read(params :: map(), Context.t()) ::
              {:ok, Result.t()} | {:error, Error.t() | term()}
  @callback complete(Completion.t(), Context.t()) ::
              {:ok, Result.t()} | {:error, Error.t() | term()}
  @optional_callbacks complete: 2

  defmacro __using__(opts_ast) do
    opts = literal_options!(__CALLER__, opts_ast)
    definition = compile_definition!(__CALLER__, opts)

    matches_body =
      case definition do
        %Definition{kind: :resource, uri: expected} ->
          quote(do: uri == unquote(expected))

        %Definition{kind: :template, uri_template: uri_template} ->
          compile_template_matcher(uri_template)
      end

    quote do
      @behaviour Snodo.Resource

      @impl Snodo.Resource
      def definition, do: unquote(Macro.escape(definition))

      @impl Snodo.Resource
      def matches?(uri) when is_binary(uri) do
        unquote(matches_body)
      end

      defoverridable matches?: 1
    end
  end

  @doc "Returns and validates the protocol-neutral definition for a resource module."
  @spec definition(module()) :: Definition.t()
  def definition(resource) when is_atom(resource) do
    validate_module!(resource)
    resource.definition()
  end

  @doc "Builds one text resource-content map."
  @spec text(String.t(), String.t(), keyword()) :: map()
  def text(uri, text, opts \\ [])
      when is_binary(uri) and is_binary(text) and is_list(opts) do
    uri
    |> content_base(opts)
    |> Map.put("text", text)
    |> validate_content!()
  end

  @doc "Builds one JSON text resource-content map."
  @spec json(String.t(), term(), keyword()) :: map()
  def json(uri, value, opts \\ []) when is_binary(uri) and is_list(opts) do
    unless JSONValue.valid?(value) do
      raise ArgumentError, "resource JSON content must be a JSON value"
    end

    opts = Keyword.put_new(opts, :mime_type, "application/json")
    text(uri, JSON.encode!(value), opts)
  end

  @doc "Builds one base64-encoded binary resource-content map."
  @spec blob(String.t(), String.t(), keyword()) :: map()
  def blob(uri, encoded, opts \\ [])
      when is_binary(uri) and is_binary(encoded) and is_list(opts) do
    case Base.decode64(encoded) do
      {:ok, _bytes} -> :ok
      :error -> raise ArgumentError, "resource blob must be valid base64"
    end

    uri
    |> content_base(opts)
    |> Map.put("blob", encoded)
    |> validate_content!()
  end

  @doc "Validates all resource callbacks and static metadata."
  @spec validate_module!(module()) :: :ok
  def validate_module!(resource) when is_atom(resource) do
    case Code.ensure_loaded(resource) do
      {:module, ^resource} ->
        :ok

      _not_loaded ->
        raise ArgumentError, "resource module #{inspect(resource)} could not be loaded"
    end

    require_callback!(resource, :definition, 0)
    definition = resource.definition()
    validate_definition!(resource, definition)

    callbacks =
      [matches?: 1, read: 2] ++
        if(definition.completion_arguments == [], do: [], else: [complete: 2])

    Enum.each(callbacks, fn {function, arity} ->
      require_callback!(resource, function, arity)
    end)

    if definition.kind == :template do
      case resource.matches?(definition.uri_template) do
        value when is_boolean(value) ->
          :ok

        {:ok, variables} ->
          validate_variables!(resource, variables)

        _invalid ->
          raise ArgumentError,
                "resource #{inspect(resource)} matches?/1 must return a boolean or {:ok, variables}"
      end
    end

    :ok
  end

  @doc false
  @spec validate_variables!(module(), term()) :: :ok
  def validate_variables!(resource, variables) when is_map(variables) do
    unless Enum.all?(variables, fn {key, value} -> is_binary(key) and is_binary(value) end) do
      raise ArgumentError,
            "resource #{inspect(resource)} matches?/1 must bind string variables to strings"
    end

    case Enum.filter(["uri", "_meta"], &Map.has_key?(variables, &1)) do
      [] ->
        :ok

      reserved ->
        raise ArgumentError,
              "resource #{inspect(resource)} matches?/1 bound reserved request keys: " <>
                Enum.join(reserved, ", ")
    end
  end

  def validate_variables!(resource, _variables) do
    raise ArgumentError, "resource #{inspect(resource)} matches?/1 must bind a map of variables"
  end

  @doc false
  @spec validate_content!(map()) :: map()
  def validate_content!(%{"uri" => uri} = content) when is_binary(uri) do
    validate_uri!(uri, "resource content uri")

    unless JSONValue.valid?(content) do
      raise ArgumentError, "resource content must contain only JSON values"
    end

    case {Map.fetch(content, "text"), Map.fetch(content, "blob")} do
      {{:ok, text}, :error} when is_binary(text) ->
        :ok

      {:error, {:ok, blob}} when is_binary(blob) ->
        validate_base64!(blob)

      _invalid ->
        raise ArgumentError, "resource content requires exactly one string text or blob field"
    end

    validate_optional_string!(content, "mimeType", "resource content mimeType")
    validate_annotations!(Map.get(content, "annotations", %{}))
    validate_metadata!(Map.get(content, "_meta", %{}))
    content
  end

  def validate_content!(_content) do
    raise ArgumentError, "resource content requires a URI string"
  end

  @doc false
  @spec definition_to_map(Definition.t()) :: map()
  def definition_to_map(%Definition{} = definition) do
    %{
      definition_key(definition.kind) => definition_uri(definition),
      "name" => definition.name,
      "title" => definition.title,
      "description" => definition.description,
      "mimeType" => definition.mime_type,
      "size" => definition.size,
      "icons" => definition.icons,
      "annotations" => definition.annotations,
      "_meta" => definition.metadata
    }
    |> Enum.reduce(%{}, fn
      {_key, nil}, shaped ->
        shaped

      {key, value}, shaped when key == "icons" and value == [] ->
        shaped

      {key, value}, shaped when key in ["annotations", "_meta"] and value == %{} ->
        shaped

      {key, value}, shaped ->
        Map.put(shaped, key, value)
    end)
  end

  # A template inside the simple-expansion subset gets a generated matcher that
  # also returns its bound variables. Anything else keeps the previous
  # behaviour of matching nothing, so the module must implement matches?/1.
  defp compile_template_matcher(uri_template) do
    case Template.compile(uri_template) do
      {:ok, template} ->
        quote do
          case Snodo.Resource.Template.match(unquote(Macro.escape(template)), uri) do
            {:ok, variables} -> {:ok, variables}
            :error -> false
          end
        end

      :unsupported ->
        quote(do: false)
    end
  end

  defp compile_definition!(env, opts) do
    uri = Keyword.get(opts, :uri)
    uri_template = Keyword.get(opts, :uri_template)
    name = Keyword.get(opts, :name)

    kind =
      case {uri, uri_template} do
        {uri, nil} when is_binary(uri) and uri != "" ->
          :resource

        {nil, template} when is_binary(template) and template != "" ->
          :template

        _invalid ->
          compile_error!(env, "Snodo.Resource expects exactly one :uri or :uri_template")
      end

    definition = %Definition{
      kind: kind,
      uri: uri,
      uri_template: uri_template,
      name: name,
      title: Keyword.get(opts, :title),
      description: Keyword.get(opts, :description),
      mime_type: Keyword.get(opts, :mime_type),
      size: Keyword.get(opts, :size),
      completion_arguments: Keyword.get(opts, :completion_arguments, []),
      icons: Keyword.get(opts, :icons, []),
      annotations: Keyword.get(opts, :annotations, %{}),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    validate_definition!(env.module, definition)
    definition
  rescue
    error in ArgumentError -> compile_error!(env, Exception.message(error))
  end

  defp literal_options!(env, opts_ast) do
    if Macro.quoted_literal?(opts_ast) do
      {opts, _binding} = Code.eval_quoted(opts_ast, [], env)
      opts
    else
      compile_error!(env, "Snodo.Resource options must be compile-time literals")
    end
  end

  defp validate_definition!(resource, %Definition{} = definition) do
    validate_definition_kind!(resource, definition.kind)
    validate_definition_name!(resource, definition.name)
    validate_definition_uri!(resource, definition)

    validate_optional_string_value!(definition.title, "resource title")
    validate_optional_string_value!(definition.description, "resource description")
    validate_optional_string_value!(definition.mime_type, "resource mimeType")
    validate_definition_size!(definition.size)
    validate_completion_arguments!(definition)
    validate_icons!(definition.icons)
    validate_annotations!(definition.annotations)
    validate_metadata!(definition.metadata)
    :ok
  end

  defp validate_definition!(resource, _definition) do
    raise ArgumentError,
          "resource #{inspect(resource)} definition/0 must return Snodo.Resource.Definition"
  end

  defp require_callback!(resource, function, arity) do
    unless function_exported?(resource, function, arity) do
      raise ArgumentError,
            "resource module #{inspect(resource)} does not export #{function}/#{arity}"
    end
  end

  defp validate_definition_kind!(_resource, kind) when kind in [:resource, :template], do: :ok

  defp validate_definition_kind!(resource, _kind) do
    raise ArgumentError, "resource #{inspect(resource)} returned an invalid definition kind"
  end

  defp validate_definition_name!(_resource, name) when is_binary(name) and name != "", do: :ok

  defp validate_definition_name!(resource, _name) do
    raise ArgumentError, "resource #{inspect(resource)} requires a non-empty name"
  end

  defp validate_definition_uri!(
         _resource,
         %Definition{kind: :resource, uri: uri, uri_template: nil}
       )
       when is_binary(uri) do
    validate_uri!(uri, "resource uri")
  end

  defp validate_definition_uri!(
         _resource,
         %Definition{kind: :template, uri: nil, uri_template: template}
       )
       when is_binary(template) and template != "",
       do: :ok

  defp validate_definition_uri!(resource, _definition) do
    raise ArgumentError, "resource #{inspect(resource)} must define exactly one URI form"
  end

  defp validate_definition_size!(nil), do: :ok
  defp validate_definition_size!(size) when is_integer(size) and size >= 0, do: :ok

  defp validate_definition_size!(_size) do
    raise ArgumentError, "resource size must be a non-negative integer or nil"
  end

  defp validate_completion_arguments!(%Definition{
         kind: :template,
         completion_arguments: arguments
       })
       when is_list(arguments) do
    unless Enum.uniq(arguments) == arguments and
             Enum.all?(arguments, &(is_binary(&1) and &1 != "")) do
      raise ArgumentError,
            "resource completion_arguments must contain unique non-empty strings"
    end
  end

  defp validate_completion_arguments!(%Definition{
         kind: :resource,
         completion_arguments: []
       }),
       do: :ok

  defp validate_completion_arguments!(%Definition{kind: :resource}) do
    raise ArgumentError, "only resource templates may declare completion_arguments"
  end

  defp validate_completion_arguments!(%Definition{}) do
    raise ArgumentError, "resource completion_arguments must be a list"
  end

  defp content_base(uri, opts) do
    %{
      "uri" => uri,
      "mimeType" => Keyword.get(opts, :mime_type),
      "annotations" => Keyword.get(opts, :annotations, %{}),
      "_meta" => Keyword.get(opts, :metadata, %{})
    }
    |> Enum.reduce(%{}, fn
      {_key, nil}, content -> content
      {_key, value}, content when value == %{} -> content
      {key, value}, content -> Map.put(content, key, value)
    end)
  end

  defp validate_uri!(uri, label) do
    case URI.new(uri) do
      {:ok, %URI{scheme: scheme}} when is_binary(scheme) and scheme != "" -> :ok
      _invalid -> raise ArgumentError, "#{label} must be an absolute URI"
    end
  end

  defp validate_icons!(icons) when is_list(icons) do
    Enum.each(icons, &validate_icon!/1)
  end

  defp validate_icons!(_icons), do: raise(ArgumentError, "resource icons must be a list")

  defp validate_icon!(%{"src" => src} = icon) when is_binary(src) do
    validate_uri!(src, "resource icon src")
    validate_optional_string!(icon, "mimeType", "resource icon mimeType")
    validate_icon_sizes!(Map.fetch(icon, "sizes"))
    validate_icon_theme!(Map.fetch(icon, "theme"))

    unless JSONValue.valid?(icon),
      do: raise(ArgumentError, "resource icon must contain only JSON values")
  end

  defp validate_icon!(_icon) do
    raise ArgumentError, "each resource icon requires a URI string src"
  end

  defp validate_icon_sizes!({:ok, sizes}) when is_list(sizes) do
    unless Enum.all?(sizes, &is_binary/1),
      do: raise(ArgumentError, "resource icon sizes must be strings")
  end

  defp validate_icon_sizes!({:ok, _invalid}) do
    raise ArgumentError, "resource icon sizes must be a list"
  end

  defp validate_icon_sizes!(:error), do: :ok

  defp validate_icon_theme!({:ok, theme}) when theme in ["light", "dark"], do: :ok

  defp validate_icon_theme!({:ok, _invalid}) do
    raise ArgumentError, "resource icon theme must be light or dark"
  end

  defp validate_icon_theme!(:error), do: :ok

  defp validate_annotations!(annotations) when is_map(annotations) do
    unless JSONValue.valid?(annotations),
      do: raise(ArgumentError, "resource annotations must contain only JSON values")

    validate_annotation_audience!(Map.fetch(annotations, "audience"))
    validate_annotation_priority!(Map.fetch(annotations, "priority"))
    validate_optional_string!(annotations, "lastModified", "resource annotation lastModified")
  end

  defp validate_annotations!(_annotations) do
    raise ArgumentError, "resource annotations must be a map"
  end

  defp validate_annotation_audience!({:ok, audience}) when is_list(audience) do
    unless Enum.all?(audience, &(&1 in ["user", "assistant"])),
      do: raise(ArgumentError, "resource annotation audience is invalid")
  end

  defp validate_annotation_audience!({:ok, _invalid}) do
    raise ArgumentError, "resource annotation audience must be a list"
  end

  defp validate_annotation_audience!(:error), do: :ok

  defp validate_annotation_priority!({:ok, priority})
       when is_number(priority) and priority >= 0 and priority <= 1,
       do: :ok

  defp validate_annotation_priority!({:ok, _invalid}) do
    raise ArgumentError, "resource annotation priority must be 0 through 1"
  end

  defp validate_annotation_priority!(:error), do: :ok

  defp validate_metadata!(metadata) when is_map(metadata) do
    valid? =
      Enum.all?(metadata, fn {key, value} ->
        is_binary(key) and Regex.match?(@meta_key, key) and JSONValue.valid?(value)
      end)

    unless valid?, do: raise(ArgumentError, "resource _meta contains an invalid entry")
  end

  defp validate_metadata!(_metadata), do: raise(ArgumentError, "resource _meta must be a map")

  defp validate_optional_string!(map, key, label) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) -> :ok
      {:ok, _invalid} -> raise ArgumentError, "#{label} must be a string"
      :error -> :ok
    end
  end

  defp validate_optional_string_value!(nil, _label), do: :ok
  defp validate_optional_string_value!(value, _label) when is_binary(value), do: :ok

  defp validate_optional_string_value!(_value, label) do
    raise ArgumentError, "#{label} must be a string or nil"
  end

  defp validate_base64!(encoded) do
    case Base.decode64(encoded) do
      {:ok, _bytes} -> :ok
      :error -> raise ArgumentError, "resource blob must be valid base64"
    end
  end

  defp definition_key(:resource), do: "uri"
  defp definition_key(:template), do: "uriTemplate"
  defp definition_uri(%Definition{kind: :resource, uri: uri}), do: uri
  defp definition_uri(%Definition{kind: :template, uri_template: template}), do: template

  @spec compile_error!(Macro.Env.t(), String.t()) :: no_return()
  defp compile_error!(env, description) do
    raise CompileError, file: env.file, line: env.line, description: description
  end
end
