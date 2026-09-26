defmodule Snodo.Server.Supervisor do
  @moduledoc "Optional supervision boundary for configured transport children."

  use Supervisor

  alias Snodo.Server.Runtime

  @doc """
  Starts a `:one_for_one` supervisor with one child per configured transport.

  The child spec that `use Snodo.Server` defines starts this supervisor. It
  takes `:transports` and `:supervisor_name` (passed here as `:name`) along
  with runtime overrides.

  Options:

    * `:runtime` - the `Snodo.Server.Runtime` given to every transport.
      Required.
    * `:transports` - the transport children. Defaults to `[]`. Each entry
      is a module, started as `{module, runtime: runtime}`; a
      `{module, opts}` tuple, started with `:runtime` added to `opts` unless
      already present; or a child spec map, used as given.
    * `:name` - a name to register the supervisor under.
  """
  def start_link(opts) when is_list(opts) do
    case Keyword.get(opts, :name) do
      nil -> Supervisor.start_link(__MODULE__, opts)
      name -> Supervisor.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    runtime = Keyword.fetch!(opts, :runtime)
    transports = Keyword.get(opts, :transports, [])

    children = Enum.map(transports, &transport_child(&1, runtime))
    Supervisor.init(children, strategy: :one_for_one)
  end

  defp transport_child(module, %Runtime{} = runtime) when is_atom(module) do
    {module, [runtime: runtime]}
  end

  defp transport_child({module, opts}, %Runtime{} = runtime)
       when is_atom(module) and is_list(opts) do
    {module, Keyword.put_new(opts, :runtime, runtime)}
  end

  defp transport_child(child_spec, %Runtime{}) when is_map(child_spec), do: child_spec
end
