defmodule MCP.Server.Supervisor do
  @moduledoc "Optional supervision boundary for configured transport children."

  use Supervisor

  alias MCP.Server.Runtime

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
