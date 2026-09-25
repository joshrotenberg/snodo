defmodule SnodoTest.TestCompletions.PackagePrompt do
  use Snodo.Prompt,
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
    {:ok,
     Snodo.Result.prompt_get(Snodo.Prompt.message(:user, Snodo.Prompt.text("Analyze #{name}.")))}
  end

  @impl true
  def complete(%Snodo.Completion{argument: "name", value: value}, _context) do
    values = Enum.filter(@packages, &String.starts_with?(&1, value))
    {:ok, Snodo.Result.completion(values, total: length(values), has_more: false)}
  end

  def complete(%Snodo.Completion{argument: "focus", value: value}, _context) do
    values = Enum.filter(@focuses, &String.starts_with?(&1, value))
    {:ok, Snodo.Result.completion(values, total: length(values))}
  end
end

defmodule SnodoTest.TestCompletions.RepositoryTemplate do
  use Snodo.Resource,
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
    {:ok, Snodo.Result.resource_read(Snodo.Resource.text(uri, "repository"))}
  end

  @impl true
  def complete(%Snodo.Completion{argument: "owner", value: value}, _context) do
    values = Enum.filter(@owners, &String.starts_with?(&1, value))
    {:ok, Snodo.Result.completion(values, total: length(values))}
  end

  def complete(
        %Snodo.Completion{
          argument: "name",
          value: value,
          arguments: %{"owner" => owner}
        },
        _context
      ) do
    values = @repositories |> Map.get(owner, []) |> Enum.filter(&String.starts_with?(&1, value))
    {:ok, Snodo.Result.completion(values, total: length(values), has_more: false)}
  end

  def complete(%Snodo.Completion{argument: "name"}, _context) do
    {:ok, Snodo.Result.completion([])}
  end
end

defmodule SnodoTest.TestCompletions.DeclaredError do
  use Snodo.Prompt,
    name: "completion_declared_error",
    arguments: [%{"name" => "value"}],
    completion_arguments: ["value"]

  @impl true
  def render(_arguments, _context), do: {:ok, Snodo.Result.prompt_get([])}

  @impl true
  def complete(_completion, _context) do
    {:error, Snodo.Error.invalid_params("Completion access denied")}
  end
end

defmodule SnodoTest.TestCompletions.WrongKind do
  use Snodo.Prompt,
    name: "completion_wrong_kind",
    arguments: [%{"name" => "value"}],
    completion_arguments: ["value"]

  @impl true
  def render(_arguments, _context), do: {:ok, Snodo.Result.prompt_get([])}

  @impl true
  def complete(_completion, _context), do: {:ok, Snodo.Result.text("wrong")}
end

defmodule SnodoTest.TestCompletions.InvalidResult do
  use Snodo.Prompt,
    name: "completion_invalid_result",
    arguments: [%{"name" => "value"}],
    completion_arguments: ["value"]

  @impl true
  def render(_arguments, _context), do: {:ok, Snodo.Result.prompt_get([])}

  @impl true
  def complete(_completion, _context) do
    {:ok, Snodo.Result.completion(Enum.map(1..101, &Integer.to_string/1))}
  end
end

defmodule SnodoTest.TestCompletions.Raising do
  use Snodo.Prompt,
    name: "completion_raising",
    arguments: [%{"name" => "value"}],
    completion_arguments: ["value"]

  @impl true
  def render(_arguments, _context), do: {:ok, Snodo.Result.prompt_get([])}

  # Raising is the point: the router must isolate a fixture fault. The spec
  # states that so Dialyzer does not report it as an accidental no_return.
  @spec complete(Snodo.Completion.t(), Snodo.Context.t()) :: no_return()
  @impl true
  def complete(_completion, _context), do: raise("private completion fixture detail")
end
