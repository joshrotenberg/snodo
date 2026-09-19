defmodule MCPEx.TestResources.StaticText do
  use MCP.Resource,
    uri: "test://static/readme",
    name: "static_readme",
    title: "Static README",
    description: "A protocol-neutral text resource fixture",
    mime_type: "text/markdown",
    size: 18,
    icons: [
      %{
        "src" => "https://example.test/readme.svg",
        "mimeType" => "image/svg+xml",
        "sizes" => ["any"],
        "theme" => "dark",
        "com.example/icon" => "preserved"
      }
    ],
    annotations: %{
      "audience" => ["user"],
      "priority" => 0.8,
      "lastModified" => "2026-08-25T00:00:00Z",
      "com.example/tag" => "fixture"
    },
    metadata: %{
      "com.example/resource" => %{"tier" => "fixture", "nested" => [true, 7, nil]}
    }

  @impl true
  def read(%{"uri" => uri}, _context) do
    content =
      MCP.Resource.text(uri, "# Static resource\n",
        mime_type: "text/markdown",
        annotations: %{"audience" => ["assistant"], "priority" => 0.4},
        metadata: %{"com.example/content" => %{"preserved" => true}}
      )

    {:ok,
     MCP.Result.resource_read(content,
       metadata: %{"com.example/result" => %{"kind" => "text"}}
     )}
  end
end

defmodule MCPEx.TestResources.StaticJSON do
  use MCP.Resource,
    uri: "test://static/data",
    name: "static_data",
    mime_type: "application/json"

  @impl true
  def read(%{"uri" => uri}, _context) do
    value = %{
      "name" => "resource-json",
      "nested" => %{"values" => [true, 7, nil]}
    }

    {:ok,
     MCP.Result.resource_read(
       MCP.Resource.json(uri, value, metadata: %{"com.example/content" => "json"}),
       metadata: %{"com.example/result" => %{"kind" => "json"}}
     )}
  end
end

defmodule MCPEx.TestResources.StaticBlob do
  use MCP.Resource,
    uri: "test://static/blob",
    name: "static_blob",
    mime_type: "application/octet-stream"

  @bytes <<0, 1, 2, 127, 128, 255>>

  @impl true
  def read(%{"uri" => uri}, _context) do
    {:ok,
     MCP.Result.resource_read(
       MCP.Resource.blob(uri, Base.encode64(@bytes),
         mime_type: "application/octet-stream",
         annotations: %{"audience" => ["assistant"]},
         metadata: %{"com.example/content" => "blob"}
       ),
       metadata: %{"com.example/result" => %{"kind" => "blob"}}
     )}
  end
end

defmodule MCPEx.TestResources.PackageTemplate do
  use MCP.Resource,
    uri_template: "test://packages/{name}",
    name: "package",
    title: "Package details",
    description: "A template whose application owns exact URI matching",
    mime_type: "application/json",
    annotations: %{"audience" => ["user", "assistant"], "priority" => 0.7},
    metadata: %{"com.example/template" => %{"matcher" => "explicit"}}

  @package_name ~r/^[a-z][a-z0-9_]*$/

  @impl true
  def matches?(uri) when is_binary(uri) do
    match?({:ok, _name}, package_name(uri))
  end

  @impl true
  def read(%{"uri" => uri} = params, _context) do
    with {:ok, name} <- package_name(uri) do
      value = %{"name" => name, "params" => params}

      {:ok,
       MCP.Result.resource_read(
         MCP.Resource.json(uri, value,
           metadata: %{"com.example/content" => %{"template" => true}}
         )
       )}
    end
  end

  defp package_name(uri) do
    case URI.parse(uri) do
      %URI{scheme: "test", host: "packages", path: "/" <> name, query: nil, fragment: nil} ->
        if Regex.match?(@package_name, name), do: {:ok, name}, else: :error

      _other ->
        :error
    end
  end
end

defmodule MCPEx.TestResources.ArchiveTemplate do
  use MCP.Resource,
    uri_template: "test://archives/{year}/{name}",
    name: "archive",
    mime_type: "text/plain"

  @impl true
  def matches?(uri) when is_binary(uri), do: String.starts_with?(uri, "test://archives/")

  @impl true
  def read(%{"uri" => uri}, _context) do
    {:ok, MCP.Result.resource_read(MCP.Resource.text(uri, "archived"))}
  end
end

defmodule MCPEx.TestResources.ContextEcho do
  use MCP.Resource,
    uri: "test://context",
    name: "context_echo",
    mime_type: "application/json"

  @impl true
  def read(%{"uri" => uri} = params, context) do
    if owner = Map.get(params, "owner") do
      send(owner, {:resource_context, context})
    end

    value = %{
      "protocolVersion" => context.protocol_version,
      "requestId" => context.request_id,
      "auth" => context.auth,
      "metadata" => context.metadata
    }

    {:ok, MCP.Result.resource_read(MCP.Resource.json(uri, value))}
  end
end

defmodule MCPEx.TestResources.StaticTextURICollision do
  use MCP.Resource,
    uri: "test://static/readme",
    name: "static_readme_uri_collision"

  @impl true
  def read(%{"uri" => uri}, _context) do
    {:ok, MCP.Result.resource_read(MCP.Resource.text(uri, "collision"))}
  end
end

defmodule MCPEx.TestResources.StaticTextNameCollision do
  use MCP.Resource,
    uri: "test://static/name-collision",
    name: "static_readme"

  @impl true
  def read(%{"uri" => uri}, _context) do
    {:ok, MCP.Result.resource_read(MCP.Resource.text(uri, "collision"))}
  end
end

defmodule MCPEx.TestResources.PackageTemplateCollision do
  use MCP.Resource,
    uri_template: "test://packages/{name}",
    name: "package_template_collision"

  @impl true
  def matches?(uri) when is_binary(uri), do: String.starts_with?(uri, "test://packages/")

  @impl true
  def read(%{"uri" => uri}, _context) do
    {:ok, MCP.Result.resource_read(MCP.Resource.text(uri, "collision"))}
  end
end

defmodule MCPEx.TestResources.StaticShadowTemplate do
  use MCP.Resource,
    uri_template: "test://static/{name}",
    name: "static_shadow"

  @impl true
  def matches?(uri) when is_binary(uri), do: String.starts_with?(uri, "test://static/")

  @impl true
  def read(%{"uri" => uri}, _context) do
    {:ok, MCP.Result.resource_read(MCP.Resource.text(uri, "shadow"))}
  end
end

defmodule MCPEx.TestResources.AmbiguousTemplateA do
  use MCP.Resource,
    uri_template: "test://ambiguous/{first}",
    name: "ambiguous_a"

  @impl true
  def matches?(uri) when is_binary(uri), do: String.starts_with?(uri, "test://ambiguous/")

  @impl true
  def read(%{"uri" => uri}, _context) do
    {:ok, MCP.Result.resource_read(MCP.Resource.text(uri, "a"))}
  end
end

defmodule MCPEx.TestResources.AmbiguousTemplateB do
  use MCP.Resource,
    uri_template: "test://ambiguous/{second}/optional",
    name: "ambiguous_b"

  @impl true
  def matches?(uri) when is_binary(uri), do: String.starts_with?(uri, "test://ambiguous/")

  @impl true
  def read(%{"uri" => uri}, _context) do
    {:ok, MCP.Result.resource_read(MCP.Resource.text(uri, "b"))}
  end
end

defmodule MCPEx.TestResources.DeclaredError do
  use MCP.Resource,
    uri: "test://errors/declared",
    name: "declared_error"

  @impl true
  def read(_params, _context) do
    {:error, MCP.Error.invalid_params("Resource access denied", %{"reason" => "fixture"})}
  end
end

defmodule MCPEx.TestResources.TermError do
  use MCP.Resource,
    uri: "test://errors/term",
    name: "term_error"

  @impl true
  def read(_params, _context), do: {:error, :backend_offline}
end

defmodule MCPEx.TestResources.Raising do
  use MCP.Resource,
    uri: "test://errors/raise",
    name: "raising_resource"

  # Raising is the point: the router must isolate a resource fault.
  @spec read(map(), MCP.Context.t()) :: no_return()
  @impl true
  def read(_params, _context), do: raise("resource fixture exploded")
end

defmodule MCPEx.TestResources.WrongResultKind do
  use MCP.Resource,
    uri: "test://errors/wrong-kind",
    name: "wrong_result_kind"

  @impl true
  def read(_params, _context), do: {:ok, MCP.Result.text("not a resource read")}
end

defmodule MCPEx.TestResources.RaisingMatcher do
  use MCP.Resource,
    uri_template: "test://matcher/{value}",
    name: "raising_matcher"

  @impl true
  def matches?("test://matcher/boom"), do: raise("matcher fixture exploded")
  def matches?(uri) when is_binary(uri), do: String.starts_with?(uri, "test://matcher/ok/")

  @impl true
  def read(%{"uri" => uri}, _context) do
    {:ok, MCP.Result.resource_read(MCP.Resource.text(uri, "matched"))}
  end
end
