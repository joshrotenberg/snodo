defmodule Snodo.Schema.Validator.JSV do
  @moduledoc """
  Optional JSV-backed JSON Schema validation with an offline, non-casting policy.

  Install the separate `snodo_jsv` integration and select this module with
  `use Snodo.Server, schema_validator: Snodo.Schema.Validator.JSV`.

  Draft 2020-12 is the default; explicit Draft 7 is also supported. Schemas are
  checked against their bundled meta-schema before compilation. Remote schemas,
  custom dialects, mixed dialects, and JSV casting extensions are rejected.
  Unknown annotation keywords are otherwise preserved. The safety scan treats
  schema-control and casting keywords conservatively even in annotation data.

  `validate/2` compiles on each call and has no global cache. Applications can
  retain an immutable root from `compile/1` or `compile/2` and use
  `validate_compiled/2` in their own validator module for a fixed catalog.
  Neither operation returns transformed data or changes advertised schemas.

  Invalid instances return `{:error, reason}`. Schema build failures raise
  `Snodo.Schema.Validator.JSV.BuildError` from `validate/2`, so the MCP router
  reports a server configuration error rather than blaming client arguments.
  `compile/2` returns those errors as tuples for startup-time admission.
  """

  @behaviour Snodo.Schema.Validator

  alias Snodo.JSONValue
  alias Snodo.Schema.Validator.JSV.BuildError
  alias Snodo.Schema.Validator.JSV.Compiled
  alias Snodo.Schema.Validator.JSV.OfflineResolver
  alias Snodo.Schema.Validator.JSV.Policy

  @draft202012 "https://json-schema.org/draft/2020-12/schema"
  @draft7 "http://json-schema.org/draft-07/schema"
  @build_options [
    resolver: OfflineResolver,
    default_meta: @draft202012,
    atoms: false,
    formats: nil,
    warnings: :silent
  ]
  @validate_options [cast: false, cast_formats: false]
  @meta_roots Map.new([@draft202012, @draft7], fn dialect ->
                {dialect,
                 JSV.build!(
                   %{"$schema" => dialect, "$ref" => dialect},
                   Keyword.put(@build_options, :formats, true)
                 )}
              end)

  @impl true
  @spec validate(term(), map()) :: :ok | {:error, term()}
  def validate(instance, schema) do
    case compile(schema) do
      {:ok, compiled} -> validate_compiled(instance, compiled)
      {:error, error} -> raise error
    end
  end

  @doc """
  Compiles a JSON-decoded schema without network access or data casting.

  The only option is `formats: :annotation | :assertion`. The default
  `:annotation` follows the bundled 2020-12 dialect; explicit assertion uses
  JSV's built-in format validators and rejects unknown format names. Draft 7
  uses its vocabulary's format policy when this option is omitted.

  Standalone compilation accepts boolean schemas; MCP tool registration still
  requires schema maps. The compiled value should be treated as opaque.
  """
  @spec compile(map() | boolean(), keyword()) ::
          {:ok, Compiled.t()} | {:error, BuildError.t()}
  def compile(schema, options \\ []) do
    ensure_schema!(schema)
    dialect = Policy.dialect(schema)
    Policy.check!(schema, dialect)
    validate_schema!(schema, dialect)

    case JSV.build(schema, build_options!(options)) do
      {:ok, root} -> {:ok, %Compiled{root: root}}
      {:error, reason} -> {:error, %BuildError{reason: reason}}
    end
  rescue
    error in BuildError -> {:error, error}
    error -> {:error, %BuildError{reason: error}}
  end

  @doc "Validates an instance using an immutable root; the original value is never replaced."
  @spec validate_compiled(term(), Compiled.t()) :: :ok | {:error, term()}
  def validate_compiled(instance, %Compiled{root: root}) do
    if JSONValue.valid?(instance) do
      case JSV.validate(instance, root, @validate_options) do
        {:ok, _unchanged_instance} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :not_a_json_value}
    end
  end

  defp ensure_schema!(schema) do
    unless (is_map(schema) or is_boolean(schema)) and JSONValue.valid?(schema),
      do: raise(BuildError, reason: :not_a_json_schema)
  end

  defp validate_schema!(schema, dialect) do
    case JSV.validate(schema, Map.fetch!(@meta_roots, dialect), @validate_options) do
      {:ok, _schema} -> :ok
      {:error, error} -> raise BuildError, reason: {:invalid_schema, error}
    end
  end

  defp build_options!([]), do: @build_options
  defp build_options!(formats: :annotation), do: Keyword.put(@build_options, :formats, false)
  defp build_options!(formats: :assertion), do: Keyword.put(@build_options, :formats, true)
  defp build_options!(_options), do: raise(BuildError, reason: :invalid_options)
end
