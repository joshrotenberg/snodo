defmodule Snodo.OAuth.ResourceServer.ScopePolicy do
  @moduledoc """
  A `Snodo.Authorization` policy that requires scopes per component.

  The bearer plug puts the token's granted scopes in `context.auth.scopes`.
  This policy compares them with the scopes each component requires, so a
  tool, prompt, or resource is listed only for callers who may use it and a
  call without the scope is refused before the handler runs:

      use Snodo.Server,
        name: "my-server",
        version: "1.0.0",
        authorization:
          {Snodo.OAuth.ResourceServer.ScopePolicy,
           required: %{
             {:tool, "publish_package"} => ["packages:write"],
             {:resource, "release_notes"} => ["packages:read"]
           },
           default: ["mcp:read"]}

  `required` maps `{kind, name}` to the scopes that component needs, where
  `kind` is `:tool`, `:prompt`, `:resource`, or `:resource_template` and
  `name` the registered name; a resource or template may also be keyed by
  its `{kind, uri}`. A component without an entry needs `default` (an empty
  list by default). All listed scopes are required.

  A discovery refusal hides the component. An invocation refusal is the
  JSON-RPC error below, inside an HTTP 200, because the request itself was
  authenticated; its data mirrors the `WWW-Authenticate` parameters of an
  RFC 6750 `insufficient_scope` challenge, so a client can start a step-up
  authorization with the listed scope:

      %{"code" => -32003, "message" => "Insufficient scope for tool publish_package",
        "data" => %{"error" => "insufficient_scope", "scope" => "packages:write"}}

  ## Options

  | Option | Default | Meaning |
  |---|---|---|
  | `:required` | `%{}` | Scopes per component |
  | `:default` | `[]` | Scopes for components without an entry |
  | `:code` | -32003 | The JSON-RPC error code of a refusal |
  | `:resource_metadata` | omitted | Added to the error data, for clients that need the document URL |

  A context without an auth map, or with one that carries no `scopes` list,
  has no scopes: over stdio or without the bearer plug, only components
  requiring nothing are reachable.
  """

  @behaviour Snodo.Authorization

  alias Snodo.Authorization.Component
  alias Snodo.Context
  alias Snodo.Error

  @impl true
  def authorize(_phase, %Component{} = component, %Context{} = context, options) do
    required = required_scopes(options, component)

    if required -- scopes(context) == [],
      do: :ok,
      else: {:error, refusal(component, required, options)}
  end

  @doc """
  The scopes granted to `context`, from the bearer plug's assign.
  """
  @spec scopes(Context.t()) :: [String.t()]
  def scopes(%Context{auth: %{scopes: scopes}}) when is_list(scopes), do: scopes
  def scopes(%Context{}), do: []

  defp required_scopes(options, %Component{kind: kind, name: name, uri: uri}) do
    required = option(options, :required, %{})
    default = option(options, :default, [])

    case Map.fetch(required, {kind, name}) do
      {:ok, scopes} -> scopes
      :error when is_binary(uri) -> Map.get(required, {kind, uri}, default)
      :error -> default
    end
  end

  defp refusal(%Component{kind: kind, name: name}, required, options) do
    data = %{"error" => "insufficient_scope", "scope" => Enum.join(required, " ")}

    data =
      case option(options, :resource_metadata, nil) do
        nil -> data
        url -> Map.put(data, "resource_metadata", url)
      end

    Error.authorization(
      option(options, :code, -32_003),
      "Insufficient scope for #{kind} #{name}",
      data
    )
  end

  defp option(options, key, default) when is_list(options), do: Keyword.get(options, key, default)
  defp option(options, key, default) when is_map(options), do: Map.get(options, key, default)
end
