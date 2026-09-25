defmodule SnodoTest.PlugFixtures.Tool do
  @moduledoc false
  use Snodo.Tool, name: "inspect_context"

  @impl true
  def call(arguments, context) do
    auth = context.auth || %{}
    owner = auth[:observer]
    if owner, do: send(owner, {:tool_entered, context.request_id, self(), context.cancellation})
    if arguments["wait"], do: Process.sleep(:infinity)
    if arguments["progress"], do: report_progress(context, owner)
    if arguments["wait_after_progress"], do: Process.sleep(:infinity)

    {:ok,
     Snodo.Result.structured(%{"principal" => auth[:principal], "text" => arguments["text"]})}
  end

  defp report_progress(context, owner) do
    first = Snodo.Progress.report(context, 1, total: 2, message: "first")
    second = Snodo.Progress.report(context, 2, total: 2, message: "second")
    if owner, do: send(owner, {:progress_replies, first, second})
  end
end

defmodule SnodoTest.PlugFixtures.Probe do
  @moduledoc false
  use Snodo.Tool, name: "probe_side_effect"

  @impl true
  def call(_arguments, context) do
    if owner = context.auth[:observer], do: send(owner, :probe_side_effect_ran)
    {:ok, Snodo.Result.text("ran")}
  end
end

defmodule SnodoTest.PlugFixtures.Policy do
  @moduledoc false
  @behaviour Snodo.Authorization

  alias Snodo.Authorization.Component

  @impl true
  def authorize(phase, %Component{} = component, context, options) do
    principal = context.auth[:principal]

    if component.name in Map.get(options.allowed, principal, []) do
      :ok
    else
      if phase == :invocation,
        do: send(options.owner, {:authorization_refused, principal, component.name})

      {:error, Snodo.Error.authorization(-32_003, "Application policy refused #{component.name}")}
    end
  end
end

defmodule SnodoTest.PlugFixtures.Endpoint do
  @moduledoc false
  @behaviour Plug

  @impl true
  def init(opts) do
    {Keyword.fetch!(opts, :observer), Snodo.Transport.Plug.init(Keyword.delete(opts, :observer))}
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

    Snodo.Transport.Plug.call(conn, opts)
  end

  defp authenticate(conn, principal, observer) do
    conn
    |> Plug.Conn.assign(:mcp_auth, %{principal: principal, observer: observer})
    |> Plug.Conn.assign(:mcp_cancellation_scope, "fixture-client-instance")
  end
end

defmodule SnodoTest.PlugFixtures do
  @moduledoc false
  alias SnodoTest.PlugFixtures.Tool

  def runtime(hub, opts \\ []) do
    Snodo.Server.Runtime.new(
      router:
        opts
        |> Keyword.get(:tools, [Tool])
        |> Enum.reduce(Snodo.Router.new(), &Snodo.Router.register_tool(&2, &1)),
      protocols: Keyword.get(opts, :protocols, [Snodo.Protocol.V2026_07_28]),
      server_info: %{"name" => "plug-acceptance", "version" => "0.1.0"},
      capabilities: Keyword.get(opts, :capabilities, %{"tools" => %{"listChanged" => true}}),
      subscription_source: Snodo.Subscription.Hub.source(hub),
      authorization: Keyword.get(opts, :authorization)
    )
  end
end
