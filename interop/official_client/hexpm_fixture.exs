# Run the real application's public server against seeded domain responses.
# Build the sibling application first; this fixture does not invoke Mix or
# replace any application callbacks. The Node check owns transport lifecycle.
project =
  System.get_env("HEXPM_MCP_PROJECT") || Path.expand("../../../hexpm-mcp", __DIR__)

build_path = System.get_env("HEXPM_MCP_BUILD_PATH") || Path.join(project, "_build/dev")
Code.prepend_paths(Path.wildcard(Path.join(build_path, "lib/*/ebin")))

if framework_ebin = System.get_env("SNODO_EBIN") do
  true = Code.prepend_path(framework_ebin)
end

Application.put_all_env(
  hexpm_mcp: [
    transport: :none,
    cache_ttl: 3600,
    docs_cache_ttl: 3600,
    rate_limit_ms: 0,
    # A missed fixture entry cannot reach the public services.
    hex_api_url: "http://127.0.0.1:1",
    hexdocs_url: "http://127.0.0.1:1",
    toolbox_url: "http://127.0.0.1:1",
    osv_url: "http://127.0.0.1:1"
  ]
)

Logger.configure(level: :error)
{:ok, _applications} = Application.ensure_all_started(:hexpm_mcp)

package =
  HexpmMcp.Types.parse_package(%{
    "name" => "interop_package",
    "latest_version" => "1.2.3",
    "latest_stable_version" => "1.2.3",
    "inserted_at" => "2026-01-01T00:00:00Z",
    "updated_at" => "2026-07-28T00:00:00Z",
    "meta" => %{
      "description" => "Seeded official-client acceptance package",
      "licenses" => ["MIT"],
      "links" => %{"Source" => "https://example.invalid/interop_package"}
    },
    "downloads" => %{"all" => 1234, "recent" => 100, "week" => 20, "day" => 3}
  })

groups = [
  %{
    title: "Web",
    slug: "web",
    categories: [%{name: "HTTP clients", slug: "http-clients", description: "HTTP libraries"}]
  }
]

projects = [
  %{
    name: "interop_package",
    description: "Seeded category member",
    downloads: %{"all" => 1234},
    github: %{stars: 42, archived: false}
  }
]

for {key, value} <- [
      {{:package, "interop_package"}, {:ok, package}},
      {{:search, "interop", [sort: "name", page: 1]}, {:ok, [package]}},
      {{:package, "missing_interop_package"}, {:error, :not_found}},
      {{:package, "limited_interop_package"}, {:error, :rate_limited}},
      {{:toolbox_groups}, {:ok, groups}},
      {{:toolbox_category, "web", "http-clients", []}, {:ok, projects}},
      {{:modules, "interop_package", nil},
       {:ok, [%{name: "InteropPackage", type: "module", doc: "Seeded module documentation"}]}},
      {{:readme, "interop_package", nil}, {:ok, "# InteropPackage\n\nSeeded README.\n"}}
    ] do
  :ok = HexpmMcp.Cache.put(key, value)
end

runtime = HexpmMcp.MCP.Server.runtime()

case System.argv() do
  ["--stdio"] ->
    :ok = Snodo.Transport.Stdio.serve(runtime)

  ["--http"] ->
    {:ok, listener} =
      Snodo.Transport.StreamableHTTP.Server.start_link(runtime: runtime, port: 0)

    IO.puts(JSON.encode!(%{"url" => Snodo.Transport.StreamableHTTP.Server.url(listener)}))
    # Closing this pipe lets the parent cleanly stop the listener and BEAM.
    _input = IO.read(:stdio, :eof)
    :ok = GenServer.stop(listener)

  _arguments ->
    raise "usage: elixir hexpm_fixture.exs --stdio|--http"
end
