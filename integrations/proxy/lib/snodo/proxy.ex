defmodule Snodo.Proxy do
  @moduledoc """
  A supervised proxy that merges catalogs from MCP backends.

  Start a proxy with backend specifications, then pass `runtime/2` to a Snodo
  transport. Backend tools and prompts use the configured name prefix. Resource
  URIs use `mcp-proxy://<backend-id>/` so a read always reaches one backend.
  The proxy keeps one atomic catalog snapshot for discovery and routing.

      {:ok, proxy} =
        Snodo.Proxy.start_link(
          backends: [
            [id: "search", target: {:http, "http://127.0.0.1:4001/mcp"}],
            [id: "files", target: {:stdio, "file-server", []}]
          ]
        )

      runtime = Snodo.Proxy.runtime(proxy)
      {:ok, listener} = Snodo.Transport.StreamableHTTP.Server.start_link(runtime: runtime)

  A backend may also use any custom `Snodo.Client` transport target, or
  `{:direct, runtime}` for an in-process server. Backends that disconnect are
  retried every second. A rejected or conflicting catalog update retains the
  last accepted catalog and appears in `health/1`.
  """

  alias Snodo.Authorization
  alias Snodo.Proxy.Manager
  alias Snodo.Proxy.Supervisor, as: ProxySupervisor
  alias Snodo.Router
  alias Snodo.Server.Runtime

  @doc "Starts the proxy supervisor and its configured backends."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) when is_list(opts), do: ProxySupervisor.start_link(opts)

  @doc "Returns an OTP child specification for a proxy."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: Keyword.get(opts, :id, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Builds a server runtime backed by the proxy's current catalog.

  `:name` defaults to `"snodo-proxy"`, `:version` to the package version, and
  `:authorization` accepts a `Snodo.Authorization` policy. The proxy applies
  that policy to the merged catalog at discovery and invocation time.
  """
  @spec runtime(pid(), keyword()) :: Runtime.t()
  def runtime(proxy, opts \\ []) when is_pid(proxy) and is_list(opts) do
    manager = ProxySupervisor.ref(proxy, :manager)
    hub = ProxySupervisor.ref(proxy, :hub)
    authorization = opts |> Keyword.get(:authorization) |> Authorization.normalize!()

    Runtime.new(
      router: Router.new(),
      protocols: [Snodo.Protocol.V2026_07_28],
      server_info: %{
        "name" => Keyword.get(opts, :name, "snodo-proxy"),
        "version" => Keyword.get(opts, :version, package_version())
      },
      capabilities: %{
        "tools" => %{"listChanged" => true},
        "prompts" => %{"listChanged" => true},
        "resources" => %{"listChanged" => true, "subscribe" => true},
        "extensions" => %{Snodo.Proxy.Extension.id() => %{}}
      },
      extensions: [
        {Snodo.Proxy.Extension, %{manager: manager, proxy: proxy, authorization: authorization}}
      ],
      subscription_source:
        {Snodo.Proxy.SubscriptionSource, %{proxy: proxy, hub: hub, authorization: authorization}}
    )
  end

  @doc "Adds and connects a backend, rejecting duplicate IDs or catalog collisions."
  @spec add_backend(pid(), keyword() | map()) :: :ok | {:error, term()}
  def add_backend(proxy, backend), do: Manager.add(child!(proxy, Manager), backend)

  @doc "Removes a backend and its published catalog entries."
  @spec remove_backend(pid(), String.t()) :: :ok | {:error, :not_found}
  def remove_backend(proxy, id), do: Manager.remove(child!(proxy, Manager), id)

  @doc "Refreshes one backend's catalog immediately."
  @spec refresh_backend(pid(), String.t()) :: :ok | {:error, term()}
  def refresh_backend(proxy, id), do: Manager.refresh(child!(proxy, Manager), id)

  @doc "Returns each configured backend's connection and catalog status."
  @spec health(pid()) :: map()
  def health(proxy), do: Manager.health(child!(proxy, Manager))

  defp child!(proxy, module) do
    case ProxySupervisor.child(proxy, module) do
      pid when is_pid(pid) -> pid
      nil -> raise ArgumentError, "proxy supervisor is not running #{inspect(module)}"
    end
  end

  defp package_version do
    :snodo_proxy
    |> Application.spec(:vsn)
    |> to_string()
  end
end
