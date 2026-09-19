defmodule MCPEx.PlugFixtures.Tool do
  @moduledoc false
  use MCP.Tool, name: "inspect_context"

  @impl true
  def call(arguments, context) do
    auth = context.auth || %{}
    owner = auth[:observer]
    if owner, do: send(owner, {:tool_entered, context.request_id, self(), context.cancellation})
    if arguments["wait"], do: Process.sleep(:infinity)
    if arguments["progress"], do: report_progress(context, owner)
    if arguments["wait_after_progress"], do: Process.sleep(:infinity)

    {:ok, MCP.Result.structured(%{"principal" => auth[:principal], "text" => arguments["text"]})}
  end

  defp report_progress(context, owner) do
    first = MCP.Progress.report(context, 1, total: 2, message: "first")
    second = MCP.Progress.report(context, 2, total: 2, message: "second")
    if owner, do: send(owner, {:progress_replies, first, second})
  end
end

defmodule MCPEx.PlugFixtures.Endpoint do
  @moduledoc false
  @behaviour Plug

  @impl true
  def init(opts) do
    {Keyword.fetch!(opts, :observer), MCP.Transport.Plug.init(Keyword.delete(opts, :observer))}
  end

  @impl true
  def call(conn, {observer, opts}) do
    send(observer, {:plug_owner, self()})

    # Deliberately tiny test-only credential lookup. Production authentication
    # remains an application concern; arbitrary header values are not identities.
    conn =
      case Plug.Conn.get_req_header(conn, "authorization") do
        ["Bearer fixture-alpha"] -> authenticate(conn, "alpha", observer)
        ["Bearer fixture-beta"] -> authenticate(conn, "beta", observer)
        _other -> conn
      end

    MCP.Transport.Plug.call(conn, opts)
  end

  defp authenticate(conn, principal, observer) do
    conn
    |> Plug.Conn.assign(:mcp_auth, %{principal: principal, observer: observer})
    |> Plug.Conn.assign(:mcp_cancellation_scope, "fixture-client-instance")
  end
end

defmodule MCPEx.PlugFixtures do
  @moduledoc false
  alias MCPEx.PlugFixtures.Tool

  def runtime(hub) do
    MCP.Server.Runtime.new(
      router: MCP.Router.new() |> MCP.Router.register_tool(Tool),
      protocols: [MCP.Protocol.V2026_07_28],
      server_info: %{"name" => "plug-acceptance", "version" => "0.1.0"},
      capabilities: %{"tools" => %{"listChanged" => true}},
      subscription_source: MCP.Subscription.Hub.source(hub)
    )
  end
end
