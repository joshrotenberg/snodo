defmodule MCPEx.TestCompletions.PackagePrompt do
  use MCP.Prompt,
    name: "package_search",
    description: "Searches Hex packages with completion-aware arguments",
    arguments: [
      %{"name" => "name", "required" => true},
      %{"name" => "focus"}
    ],
    completion_arguments: ["name", "focus"]

  @packages ["ecto", "ecto_sql", "ex_doc", "jason", "plug"]
  @focuses ["adoption", "health", "security"]

  @impl true
  def render(%{"name" => name}, _context) do
    {:ok, MCP.Result.prompt_get(MCP.Prompt.message(:user, MCP.Prompt.text("Analyze #{name}.")))}
  end

  @impl true
  def complete(%MCP.Completion{argument: "name", value: value}, _context) do
    values = Enum.filter(@packages, &String.starts_with?(&1, value))
    {:ok, MCP.Result.completion(values, total: length(values), has_more: false)}
  end

  def complete(%MCP.Completion{argument: "focus", value: value}, _context) do
    values = Enum.filter(@focuses, &String.starts_with?(&1, value))
    {:ok, MCP.Result.completion(values, total: length(values))}
  end
end

defmodule MCPEx.TestCompletions.RepositoryTemplate do
  use MCP.Resource,
    uri_template: "repo://{owner}/{name}",
    name: "repository",
    description: "Repository data with contextual owner/name completion",
    completion_arguments: ["owner", "name"]

  @owners ["elixir-ecto", "elixir-lang", "hexpm"]
  @repositories %{
    "elixir-ecto" => ["ecto", "ecto_sql"],
    "elixir-lang" => ["elixir"],
    "hexpm" => ["hex", "hexpm"]
  }

  @impl true
  def matches?(uri) when is_binary(uri), do: String.starts_with?(uri, "repo://")

  @impl true
  def read(%{"uri" => uri}, _context) do
    {:ok, MCP.Result.resource_read(MCP.Resource.text(uri, "repository"))}
  end

  @impl true
  def complete(%MCP.Completion{argument: "owner", value: value}, _context) do
    values = Enum.filter(@owners, &String.starts_with?(&1, value))
    {:ok, MCP.Result.completion(values, total: length(values))}
  end

  def complete(
        %MCP.Completion{
          argument: "name",
          value: value,
          arguments: %{"owner" => owner}
        },
        _context
      ) do
    values = @repositories |> Map.get(owner, []) |> Enum.filter(&String.starts_with?(&1, value))
    {:ok, MCP.Result.completion(values, total: length(values), has_more: false)}
  end

  def complete(%MCP.Completion{argument: "name"}, _context) do
    {:ok, MCP.Result.completion([])}
  end
end

defmodule MCPEx.TestCompletions.DeclaredError do
  use MCP.Prompt,
    name: "completion_declared_error",
    arguments: [%{"name" => "value"}],
    completion_arguments: ["value"]

  @impl true
  def render(_arguments, _context), do: {:ok, MCP.Result.prompt_get([])}

  @impl true
  def complete(_completion, _context) do
    {:error, MCP.Error.invalid_params("Completion access denied")}
  end
end

defmodule MCPEx.TestCompletions.WrongKind do
  use MCP.Prompt,
    name: "completion_wrong_kind",
    arguments: [%{"name" => "value"}],
    completion_arguments: ["value"]

  @impl true
  def render(_arguments, _context), do: {:ok, MCP.Result.prompt_get([])}

  @impl true
  def complete(_completion, _context), do: {:ok, MCP.Result.text("wrong")}
end

defmodule MCPEx.TestCompletions.InvalidResult do
  use MCP.Prompt,
    name: "completion_invalid_result",
    arguments: [%{"name" => "value"}],
    completion_arguments: ["value"]

  @impl true
  def render(_arguments, _context), do: {:ok, MCP.Result.prompt_get([])}

  @impl true
  def complete(_completion, _context) do
    {:ok, MCP.Result.completion(Enum.map(1..101, &Integer.to_string/1))}
  end
end

defmodule MCPEx.TestCompletions.Raising do
  use MCP.Prompt,
    name: "completion_raising",
    arguments: [%{"name" => "value"}],
    completion_arguments: ["value"]

  @impl true
  def render(_arguments, _context), do: {:ok, MCP.Result.prompt_get([])}

  @impl true
  def complete(_completion, _context), do: raise("private completion fixture detail")
end
