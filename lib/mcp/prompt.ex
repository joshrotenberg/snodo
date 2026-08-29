defmodule MCP.Prompt do
  @moduledoc """
  Behaviour, compile-time DSL, and content builders for MCP prompts.

  Prompt arguments are deliberately the flat string map defined by MCP rather
  than JSON Schema. Required arguments are checked by the router before
  `render/2` runs. A prompt returns one or more user/assistant messages through
  `MCP.Result.prompt_get/2`.
  """

  alias MCP.Completion
  alias MCP.Context
  alias MCP.Error
  alias MCP.JSONValue
  alias MCP.Prompt.Definition
  alias MCP.Resource
  alias MCP.Result

  @meta_key ~r/^(?:(?:[A-Za-z](?:[A-Za-z0-9-]*[A-Za-z0-9])?)(?:\.(?:[A-Za-z](?:[A-Za-z0-9-]*[A-Za-z0-9])?))*\/)?(?:[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?)?$/

  @callback definition() :: Definition.t()
  @callback render(arguments :: %{optional(String.t()) => String.t()}, Context.t()) ::
              {:ok, Result.t()} | {:error, Error.t() | term()}
  @callback complete(Completion.t(), Context.t()) ::
              {:ok, Result.t()} | {:error, Error.t() | term()}
  @optional_callbacks complete: 2

  defmacro __using__(opts_ast) do
    opts = literal_options!(__CALLER__, opts_ast)
    definition = compile_definition!(__CALLER__, opts)

    quote do
      @behaviour MCP.Prompt

      @impl MCP.Prompt
      def definition, do: unquote(Macro.escape(definition))
    end
  end

  @doc "Returns and validates the protocol-neutral definition for a prompt module."
  @spec definition(module()) :: Definition.t()
  def definition(prompt) when is_atom(prompt) do
    validate_module!(prompt)
    prompt.definition()
  end

  @doc "Builds a prompt message with a user or assistant role."
  @spec message(:user | :assistant | String.t(), map()) :: map()
  def message(role, content) when role in [:user, :assistant] do
    message(Atom.to_string(role), content)
  end

  def message(role, content) when role in ["user", "assistant"] and is_map(content) do
    %{"role" => role, "content" => content}
    |> validate_message!()
  end

  @doc "Builds text content for a prompt message."
  @spec text(String.t(), keyword()) :: map()
  def text(value, opts \\ []) when is_binary(value) and is_list(opts) do
    %{"type" => "text", "text" => value}
    |> put_content_options(opts)
    |> validate_content!()
  end

  @doc "Builds base64-encoded image content for a prompt message."
  @spec image(String.t(), String.t(), keyword()) :: map()
  def image(encoded, mime_type, opts \\ [])
      when is_binary(encoded) and is_binary(mime_type) and is_list(opts) do
    %{"type" => "image", "data" => encoded, "mimeType" => mime_type}
    |> put_content_options(opts)
    |> validate_content!()
  end

  @doc "Builds base64-encoded audio content for a prompt message."
  @spec audio(String.t(), String.t(), keyword()) :: map()
  def audio(encoded, mime_type, opts \\ [])
      when is_binary(encoded) and is_binary(mime_type) and is_list(opts) do
    %{"type" => "audio", "data" => encoded, "mimeType" => mime_type}
    |> put_content_options(opts)
    |> validate_content!()
  end

  @doc "Builds embedded resource content for a prompt message."
  @spec embedded_resource(map(), keyword()) :: map()
  def embedded_resource(resource_content, opts \\ [])
      when is_map(resource_content) and is_list(opts) do
    %{"type" => "resource", "resource" => resource_content}
    |> put_content_options(opts)
    |> validate_content!()
  end

  @doc "Builds a resource link for a prompt message."
  @spec resource_link(String.t(), String.t(), keyword()) :: map()
  def resource_link(uri, name, opts \\ [])
      when is_binary(uri) and is_binary(name) and is_list(opts) do
    %{
      "type" => "resource_link",
      "uri" => uri,
      "name" => name,
      "title" => Keyword.get(opts, :title),
      "description" => Keyword.get(opts, :description),
      "mimeType" => Keyword.get(opts, :mime_type),
      "size" => Keyword.get(opts, :size),
      "icons" => Keyword.get(opts, :icons, [])
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == [] end)
    |> Map.new()
    |> put_content_options(opts)
    |> validate_content!()
  end

  @doc false
  @spec validate_module!(module()) :: :ok
  def validate_module!(prompt) when is_atom(prompt) do
    case Code.ensure_loaded(prompt) do
      {:module, ^prompt} -> :ok
      _not_loaded -> raise ArgumentError, "prompt module #{inspect(prompt)} could not be loaded"
    end

    require_callback!(prompt, :definition, 0)
    definition = prompt.definition()
    validate_definition!(prompt, definition)

    callbacks =
      [render: 2] ++
        if(definition.completion_arguments == [], do: [], else: [complete: 2])

    Enum.each(callbacks, fn {function, arity} ->
      require_callback!(prompt, function, arity)
    end)

    :ok
  end

  @doc false
  @spec definition_to_map(Definition.t()) :: map()
  def definition_to_map(%Definition{} = definition) do
    %{
      "name" => definition.name,
      "title" => definition.title,
      "description" => definition.description,
      "arguments" => definition.arguments,
      "icons" => definition.icons,
      "_meta" => definition.metadata
    }
    |> Enum.reject(fn
      {_key, nil} -> true
      {key, []} when key in ["arguments", "icons"] -> true
      {"_meta", metadata} when metadata == %{} -> true
      _entry -> false
    end)
    |> Map.new()
  end

  @doc false
  @spec validate_message!(map()) :: map()
  def validate_message!(%{"role" => role, "content" => content} = message)
      when role in ["user", "assistant"] and is_map(content) do
    unless map_size(message) == 2 and JSONValue.valid?(message) do
      raise ArgumentError, "prompt message must contain only role and content JSON fields"
    end

    _ = validate_content!(content)
    message
  end

  def validate_message!(_message) do
    raise ArgumentError, "prompt message requires a user/assistant role and content object"
  end

  @doc false
  @spec validate_content!(map()) :: map()
  def validate_content!(%{"type" => "text", "text" => text} = content)
      when is_binary(text) do
    validate_common_content!(content, ["type", "text", "annotations", "_meta"])
  end

  def validate_content!(%{"type" => type, "data" => data, "mimeType" => mime_type} = content)
      when type in ["image", "audio"] and is_binary(data) and is_binary(mime_type) do
    validate_base64!(data, "prompt #{type} data")
    validate_common_content!(content, ["type", "data", "mimeType", "annotations", "_meta"])
  end

  def validate_content!(%{"type" => "resource", "resource" => resource} = content)
      when is_map(resource) do
    _ = Resource.validate_content!(resource)
    validate_common_content!(content, ["type", "resource", "annotations", "_meta"])
  end

  def validate_content!(%{"type" => "resource_link"} = content) do
    validate_resource_link!(content)
  end

  def validate_content!(_content) do
    raise ArgumentError, "prompt content is not a supported MCP content block"
  end

  defp compile_definition!(env, opts) do
    definition = %Definition{
      name: Keyword.get(opts, :name),
      title: Keyword.get(opts, :title),
      description: Keyword.get(opts, :description),
      arguments: Keyword.get(opts, :arguments, []),
      completion_arguments: Keyword.get(opts, :completion_arguments, []),
      icons: Keyword.get(opts, :icons, []),
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
      compile_error!(env, "MCP.Prompt options must be compile-time literals")
    end
  end

  defp validate_definition!(prompt, %Definition{} = definition) do
    unless is_binary(definition.name) and definition.name != "" do
      raise ArgumentError, "prompt #{inspect(prompt)} requires a non-empty name"
    end

    validate_optional_string_value!(definition.title, "prompt title")
    validate_optional_string_value!(definition.description, "prompt description")
    validate_arguments!(definition.arguments)
    validate_completion_arguments!(definition.completion_arguments, definition.arguments)
    validate_icons!(definition.icons)
    validate_metadata!(definition.metadata)
    :ok
  end

  defp validate_definition!(prompt, _definition) do
    raise ArgumentError,
          "prompt #{inspect(prompt)} definition/0 must return MCP.Prompt.Definition"
  end

  defp require_callback!(prompt, function, arity) do
    unless function_exported?(prompt, function, arity) do
      raise ArgumentError,
            "prompt module #{inspect(prompt)} does not export #{function}/#{arity}"
    end
  end

  defp validate_arguments!(arguments) when is_list(arguments) do
    Enum.each(arguments, &validate_argument!/1)
    names = Enum.map(arguments, &Map.fetch!(&1, "name"))

    unless length(names) == length(Enum.uniq(names)) do
      raise ArgumentError, "prompt argument names must be unique"
    end
  end

  defp validate_arguments!(_arguments),
    do: raise(ArgumentError, "prompt arguments must be a list")

  defp validate_completion_arguments!(completion_arguments, arguments)
       when is_list(completion_arguments) do
    declared_arguments = MapSet.new(arguments, &Map.fetch!(&1, "name"))

    unless Enum.uniq(completion_arguments) == completion_arguments and
             Enum.all?(completion_arguments, fn name ->
               is_binary(name) and name != "" and MapSet.member?(declared_arguments, name)
             end) do
      raise ArgumentError,
            "prompt completion_arguments must be unique names declared in arguments"
    end
  end

  defp validate_completion_arguments!(_completion_arguments, _arguments) do
    raise ArgumentError, "prompt completion_arguments must be a list"
  end

  defp validate_argument!(%{"name" => name} = argument)
       when is_binary(name) and name != "" do
    allowed = ["name", "title", "description", "required"]

    unless Enum.all?(Map.keys(argument), &(&1 in allowed)) and JSONValue.valid?(argument) do
      raise ArgumentError, "prompt argument contains unsupported or non-JSON fields"
    end

    validate_optional_string!(argument, "title", "prompt argument title")
    validate_optional_string!(argument, "description", "prompt argument description")

    case Map.fetch(argument, "required") do
      {:ok, required} when is_boolean(required) -> :ok
      {:ok, _invalid} -> raise ArgumentError, "prompt argument required must be a boolean"
      :error -> :ok
    end
  end

  defp validate_argument!(_argument) do
    raise ArgumentError, "each prompt argument requires a non-empty string name"
  end

  defp validate_resource_link!(%{"uri" => uri, "name" => name} = content)
       when is_binary(uri) and is_binary(name) and name != "" do
    validate_uri!(uri, "prompt resource link uri")

    allowed = [
      "type",
      "uri",
      "name",
      "title",
      "description",
      "mimeType",
      "size",
      "icons",
      "annotations",
      "_meta"
    ]

    unless Enum.all?(Map.keys(content), &(&1 in allowed)) do
      raise ArgumentError, "prompt resource link contains unsupported fields"
    end

    validate_optional_string!(content, "title", "prompt resource link title")
    validate_optional_string!(content, "description", "prompt resource link description")
    validate_optional_string!(content, "mimeType", "prompt resource link mimeType")

    case Map.fetch(content, "size") do
      {:ok, size} when is_integer(size) and size >= 0 -> :ok
      {:ok, _invalid} -> raise ArgumentError, "prompt resource link size must be non-negative"
      :error -> :ok
    end

    validate_icons!(Map.get(content, "icons", []))
    validate_common_content!(content, allowed)
  end

  defp validate_resource_link!(_content) do
    raise ArgumentError, "prompt resource link requires string uri and name fields"
  end

  defp validate_common_content!(content, allowed) do
    unless Enum.all?(Map.keys(content), &(&1 in allowed)) and JSONValue.valid?(content) do
      raise ArgumentError, "prompt content contains unsupported or non-JSON fields"
    end

    validate_annotations!(Map.get(content, "annotations", %{}))
    validate_metadata!(Map.get(content, "_meta", %{}))
    content
  end

  defp put_content_options(content, opts) do
    content
    |> maybe_put("annotations", Keyword.get(opts, :annotations, %{}), %{})
    |> maybe_put("_meta", Keyword.get(opts, :metadata, %{}), %{})
  end

  defp validate_icons!(icons) when is_list(icons), do: Enum.each(icons, &validate_icon!/1)
  defp validate_icons!(_icons), do: raise(ArgumentError, "prompt icons must be a list")

  defp validate_icon!(%{"src" => src} = icon) when is_binary(src) do
    validate_uri!(src, "prompt icon src")
    validate_optional_string!(icon, "mimeType", "prompt icon mimeType")

    case Map.fetch(icon, "sizes") do
      {:ok, sizes} when is_list(sizes) ->
        unless Enum.all?(sizes, &is_binary/1),
          do: raise(ArgumentError, "prompt icon sizes must be strings")

      {:ok, _invalid} ->
        raise ArgumentError, "prompt icon sizes must be a list"

      :error ->
        :ok
    end

    case Map.fetch(icon, "theme") do
      {:ok, theme} when theme in ["light", "dark"] -> :ok
      {:ok, _invalid} -> raise ArgumentError, "prompt icon theme must be light or dark"
      :error -> :ok
    end

    unless JSONValue.valid?(icon),
      do: raise(ArgumentError, "prompt icon must contain only JSON values")
  end

  defp validate_icon!(_icon),
    do: raise(ArgumentError, "each prompt icon requires a URI string src")

  defp validate_annotations!(annotations) when is_map(annotations) do
    unless JSONValue.valid?(annotations),
      do: raise(ArgumentError, "prompt annotations must contain only JSON values")

    validate_annotation_audience!(Map.fetch(annotations, "audience"))
    validate_annotation_priority!(Map.fetch(annotations, "priority"))
    validate_optional_string!(annotations, "lastModified", "prompt annotation lastModified")
  end

  defp validate_annotations!(_annotations),
    do: raise(ArgumentError, "prompt annotations must be a map")

  defp validate_annotation_audience!({:ok, audience}) when is_list(audience) do
    unless Enum.all?(audience, &(&1 in ["user", "assistant"])),
      do: raise(ArgumentError, "prompt annotation audience is invalid")
  end

  defp validate_annotation_audience!({:ok, _invalid}) do
    raise ArgumentError, "prompt annotation audience must be a list"
  end

  defp validate_annotation_audience!(:error), do: :ok

  defp validate_annotation_priority!({:ok, priority})
       when is_number(priority) and priority >= 0 and priority <= 1,
       do: :ok

  defp validate_annotation_priority!({:ok, _invalid}) do
    raise ArgumentError, "prompt annotation priority must be 0 through 1"
  end

  defp validate_annotation_priority!(:error), do: :ok

  defp validate_metadata!(metadata) when is_map(metadata) do
    valid? =
      Enum.all?(metadata, fn {key, value} ->
        is_binary(key) and Regex.match?(@meta_key, key) and JSONValue.valid?(value)
      end)

    unless valid?, do: raise(ArgumentError, "prompt _meta contains an invalid entry")
  end

  defp validate_metadata!(_metadata), do: raise(ArgumentError, "prompt _meta must be a map")

  defp validate_base64!(encoded, label) do
    case Base.decode64(encoded) do
      {:ok, _bytes} -> :ok
      :error -> raise ArgumentError, "#{label} must be valid base64"
    end
  end

  defp validate_uri!(uri, label) do
    case URI.new(uri) do
      {:ok, %URI{scheme: scheme}} when is_binary(scheme) and scheme != "" -> :ok
      _invalid -> raise ArgumentError, "#{label} must be an absolute URI"
    end
  end

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

  defp maybe_put(map, _key, value, value), do: map
  defp maybe_put(map, key, value, _default), do: Map.put(map, key, value)

  @spec compile_error!(Macro.Env.t(), String.t()) :: no_return()
  defp compile_error!(env, message) do
    raise CompileError, file: env.file, line: env.line, description: message
  end
end
