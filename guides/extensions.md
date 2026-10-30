# Extensions

An extension adds negotiated behavior without changing the core protocol
profile. It implements `Snodo.Extension`, declares exact-versioned
`Snodo.Extension.Method` values, and is installed on the server:

```elixir
use Snodo.Server,
  name: "my-server",
  version: "1.0.0",
  extensions: [MyApp.Extension]
```

Runtime construction rejects duplicate extension IDs, methods that collide with
any core method (including unsupported and MRTR-only ones), and collisions
between extensions. An installed route runs only when both peers advertise the
extension and its callback accepts the negotiation. An advertised, compatible
extension may also wrap core dispatch and contribute HTTP policy through generic
hooks. An installed but unadvertised extension does nothing.

Middleware that stores or defers a call instead of passing it on calls
`Snodo.Extension.check_dispatch/3` first, so the deferred work passes the same
lookup, authorization, and argument checks as a direct call.

See `examples/06_custom_extension.exs`.

## Declared extensions

Some extensions add no methods: the server advertises them, reads what the
client declared, and attaches the extension's `_meta` to tools, resources, or
results. Declare one with its server settings instead of writing a module:

```elixir
use Snodo.Server,
  name: "my-server",
  version: "1.0.0",
  extensions: [{:declared, "com.example/charts", %{"version" => "1"}}]
```

The runtime advertises the id under `capabilities["extensions"]` with those
settings; an entry you put there yourself wins. In a handler,
`Snodo.Context.extension_settings/2` returns the settings the client sent for
the id, or `nil` when the client did not declare it, so the handler can fall
back to plain content:

```elixir
tool "sales_chart" do
  @impl true
  def call(_arguments, context) do
    case Snodo.Context.extension_settings(context, "com.example/charts") do
      nil ->
        {:ok, "Q3 sales: 120, 140, 180"}

      _client_settings ->
        {:ok,
         Snodo.Result.text("Q3 sales: 120, 140, 180",
           metadata: %{"com.example/charts" => %{"kind" => "bar", "series" => [120, 140, 180]}}
         )}
    end
  end
end
```

For a published extension, attach the `_meta` keys its specification defines.
A declared extension has no routes, middleware, or negotiation callback; write
a `Snodo.Extension` module when you need any of those.

## MCP Apps

MCP Apps (`io.modelcontextprotocol/ui`, specification 2026-01-26) links a tool
to a `ui://` resource holding an HTML document that the host renders in a
sandboxed frame. It is a declared extension, and `Snodo.Apps` returns the
shapes the specification defines:

```elixir
use Snodo.Server,
  name: "weather",
  version: "1.0.0",
  extensions: [Snodo.Apps.extension()]

tool "forecast", metadata: Snodo.Apps.tool_metadata("ui://weather/forecast") do
  argument("city", :string, required: true)

  @impl true
  def call(%{"city" => city}, context) do
    if Snodo.Apps.supported?(context) do
      {:ok, Snodo.Result.structured(%{"city" => city, "celsius" => 21})}
    else
      {:ok, "#{city}: sunny, 21 C"}
    end
  end
end

resource "forecast_view",
  uri: "ui://weather/forecast",
  mime_type: "text/html;profile=mcp-app" do
  @impl true
  def read(_params, _context) do
    {:ok,
     Snodo.Result.resource_read(
       Snodo.Apps.html("ui://weather/forecast", File.read!("priv/forecast.html"),
         csp: [connect_domains: ["https://api.weather.example"]],
         prefers_border: true
       )
     )}
  end
end
```

`tool_metadata/2` writes `_meta.ui.resourceUri`. With `visibility: [:app]`
the host hides the tool from the model and accepts calls to it only from the
UI, for actions such as a refresh button.

A host that does not implement MCP Apps ignores `_meta.ui` and shows the
tool's content, so the content should make sense as text. A host that does
implement it declares the extension with `mimeTypes` in its capabilities;
`Snodo.Apps.supported?/1` checks for `text/html;profile=mcp-app` there, so a
handler can return data for the UI to such a host and plain text to any other.
Negotiation uses `capabilities["extensions"]`, which only the 2026-07-28
dialect carries, so on the initialize-era dialects `supported?/1` is `false`.

The view's Content Security Policy goes in the content's `_meta`, which
`html/3` builds from its options. Without `:csp` the host allows no external
origins. `:connect_domains`, `:resource_domains`, `:frame_domains`, and
`:base_uri_domains` list the origins for network requests, static assets,
nested frames, and the base URI. `:permissions` asks for `:camera`,
`:microphone`, `:geolocation`, or `:clipboard_write`. `:domain` requests a
dedicated sandbox origin in the format the host documents, and
`:prefers_border` asks the host to draw or omit a border. A host may restrict
any of these further.

Resource options are compile-time literals, so the listing's `mimeType` is
written out. `html/3` sets the content's MIME type and checks its `ui://` URI. `Snodo.Apps.client_capabilities/0` is the host side of the
declaration, for `Snodo.Client` in tests.

See `examples/35_mcp_apps.exs`.

## Tasks

`snodo_tasks` implements the `io.modelcontextprotocol/tasks` extension on those
hooks. It augments `tools/call`, keeps `tasks/get`, `tasks/update`, and
`tasks/cancel` outside the core catalog, and adds `taskIds` filters and
`notifications/tasks` to subscriptions.

The application owns the store and runner. The package includes memory and
DETS stores; `snodo_tasks_postgres` and `snodo_tasks_sqlite` add
transactional stores behind an application-owned Ecto Repo. Recovery is
at-least-once, so work must use its stable idempotency key for external
effects.

- [Tasks package](https://hexdocs.pm/snodo_tasks), including the
  [stress-testing harness](https://github.com/joshrotenberg/snodo/blob/main/extensions/tasks/stress-testing.md)
- [Writing a Tasks store](https://hexdocs.pm/snodo_tasks/custom-stores.html)
- [PostgreSQL store](https://hexdocs.pm/snodo_tasks_postgres)
- [SQLite store](https://hexdocs.pm/snodo_tasks_sqlite)

Examples 07, 08, 09, 17, and 26 run from `extensions/tasks`; example 10 from
`extensions/tasks_postgres` with a live database; example 11 from
`extensions/tasks_sqlite`.
