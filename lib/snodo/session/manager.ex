defmodule Snodo.Session.Manager do
  @moduledoc """
  Starts and bounds the session processes of initialize-era clients.

  A manager owns a `Snodo.Session.Registry` and a `DynamicSupervisor` for
  `Snodo.Session` processes. `Snodo.Transport.StreamableHTTP.Server` starts its
  own when it is given `sessions: true` or a keyword list of these options.
  `Snodo.Transport.Plug` takes the name of one the application starts under
  its supervision tree, because a Plug's options can be built at compile time:

      children = [
        {Snodo.Session.Manager, name: MyApp.MCPSessions},
        {Bandit,
         plug:
           {Snodo.Transport.Plug,
            runtime: MyApp.Server.runtime(),
            executor: MyApp.Executor,
            sessions: MyApp.MCPSessions}}
      ]

  Options:

    * `:name` - a registered name for the manager.
    * `:max_sessions` - the most sessions open at once, default 1,024. An
      `initialize` over the limit gets 503 and no session.
    * `:idle_timeout` - milliseconds a session may go without a request, a
      response, or an open stream before it ends, default 1,800,000 (30
      minutes). A request for an ended session gets 404, and the client
      initializes again. `:infinity` keeps sessions until `DELETE` or shutdown.
    * `:registry` - a `Snodo.Session.Registry` module or `{module, options}`.
      Defaults to `Snodo.Session.Registry.Local`.
    * `:principal` - a function of one argument that maps a request's auth
      value (`Snodo.Context.auth`) to the principal a session is bound to.
      The default uses the `:principal` and `:client_id` fields when the auth
      value is a map with a `:principal` key, which is the shape
      `snodo_oauth` assigns, so a refreshed token for the same subject keeps
      the session; otherwise it uses the whole auth value.

  Sessions live on the node that handled `initialize`. A deployment with more
  than one node needs sticky load balancing that routes every request for a
  session to that node; the core does not route sessions between nodes.
  """

  use GenServer

  alias Snodo.Session
  alias Snodo.Session.Registry

  @default_max_sessions 1_024
  @default_idle_timeout 1_800_000

  @enforce_keys [:supervisor, :registry, :idle_timeout, :max_sessions, :principal]
  defstruct @enforce_keys

  @typedoc "The configuration of a running manager, as `config/1` returns it."
  @type t :: %__MODULE__{
          supervisor: pid(),
          registry: {module(), term()},
          idle_timeout: pos_integer() | :infinity,
          max_sessions: pos_integer(),
          principal: (term() -> term())
        }

  @doc "Starts a manager. See the module documentation for the options."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    validate!(opts)
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc "Returns the configuration of a running manager."
  @spec config(GenServer.server() | t()) :: t()
  def config(%__MODULE__{} = config), do: config
  def config(manager), do: GenServer.call(manager, :config)

  @doc "Returns the number of open sessions."
  @spec count(GenServer.server() | t()) :: non_neg_integer()
  def count(manager) do
    %{active: active} = DynamicSupervisor.count_children(config(manager).supervisor)
    active
  end

  @doc false
  # Starts a session bound to `auth`'s principal. The session is registered
  # under a new ID before this returns.
  @spec start_session(t(), Snodo.Server.Runtime.t(), term()) ::
          {:ok, Session.t()} | {:error, :limit | term()}
  def start_session(%__MODULE__{} = config, runtime, auth) do
    spec =
      {Session,
       runtime: runtime,
       principal: config.principal.(auth),
       registry: config.registry,
       idle_timeout: config.idle_timeout}

    case DynamicSupervisor.start_child(config.supervisor, spec) do
      {:ok, pid} -> {:ok, Session.info(pid)}
      {:error, :max_children} -> {:error, :limit}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, {:manager_unavailable, reason}}
  end

  @doc false
  # Finds an open session and checks that `auth` is the principal it is bound
  # to. A session bound to someone else is reported as not found, so an ID
  # alone never confirms that a session exists.
  @spec admit(t(), String.t(), term()) :: {:ok, Session.t()} | :error
  def admit(%__MODULE__{} = config, id, auth) when is_binary(id) do
    {module, options} = config.registry

    with {:ok, pid} <- module.lookup(options, id) do
      Session.admit(pid, config.principal.(auth))
    end
  end

  def admit(%__MODULE__{}, _id, _auth), do: :error

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {module, options} =
      case Keyword.get(opts, :registry, Registry.Local) do
        Registry.Local -> {Registry.Local, local_registry_name()}
        {Registry.Local, nil} -> {Registry.Local, local_registry_name()}
        registry -> Registry.normalize!(registry)
      end

    with {:ok, registry_pid} <- start_registry(module, options),
         {:ok, supervisor} <-
           DynamicSupervisor.start_link(
             strategy: :one_for_one,
             max_children: Keyword.get(opts, :max_sessions, @default_max_sessions)
           ) do
      config = %__MODULE__{
        supervisor: supervisor,
        registry: {module, options},
        idle_timeout: Keyword.get(opts, :idle_timeout, @default_idle_timeout),
        max_sessions: Keyword.get(opts, :max_sessions, @default_max_sessions),
        principal: Keyword.get(opts, :principal, &default_principal/1)
      }

      {:ok, %{config: config, registry: registry_pid}}
    end
  end

  @impl true
  def handle_call(:config, _from, state), do: {:reply, state.config, state}

  @impl true
  def handle_info({:EXIT, pid, reason}, state)
      when pid == state.config.supervisor or pid == state.registry,
      do: {:stop, reason, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    stop_child(state.config.supervisor)
    stop_child(state.registry)
    :ok
  end

  defp stop_child(pid) when is_pid(pid) do
    if Process.alive?(pid), do: Supervisor.stop(pid, :shutdown)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp stop_child(nil), do: :ok

  defp start_registry(module, options) do
    case module.child_spec(options) do
      nil ->
        {:ok, nil}

      spec ->
        %{start: {child_module, function, args}} = Supervisor.child_spec(spec, [])
        apply(child_module, function, args)
    end
  end

  defp local_registry_name do
    :"Elixir.Snodo.Session.Registry.Local.#{System.unique_integer([:positive])}"
  end

  @doc false
  def default_principal(%{principal: principal} = auth),
    do: {principal, Map.get(auth, :client_id)}

  def default_principal(auth), do: auth

  defp validate!(opts) do
    case Keyword.get(opts, :max_sessions, @default_max_sessions) do
      value when is_integer(value) and value > 0 -> :ok
      _invalid -> raise ArgumentError, ":max_sessions must be a positive integer"
    end

    case Keyword.get(opts, :idle_timeout, @default_idle_timeout) do
      :infinity -> :ok
      value when is_integer(value) and value > 0 -> :ok
      _invalid -> raise ArgumentError, ":idle_timeout must be a positive integer or :infinity"
    end

    unless is_function(Keyword.get(opts, :principal, &default_principal/1), 1),
      do: raise(ArgumentError, ":principal must be a function of one argument")

    _registry = Registry.normalize!(Keyword.get(opts, :registry, Registry.Local))

    :ok
  end
end
