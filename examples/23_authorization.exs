defmodule Examples.Authorization.ReadPackage do
  @moduledoc false
  use MCP.Tool, name: "read_package"

  @impl true
  def call(_arguments, _context), do: {:ok, MCP.Result.text("package")}
end

defmodule Examples.Authorization.PublishPackage do
  @moduledoc false
  use MCP.Tool, name: "publish_package"

  input_schema(%{
    "type" => "object",
    "properties" => %{"version" => %{"type" => "string"}},
    "required" => ["version"]
  })

  @impl true
  def call(%{"version" => version}, _context) do
    # A side effect a refused caller must never reach.
    Process.put(:published, [version | Process.get(:published, [])])
    {:ok, MCP.Result.text("published #{version}")}
  end
end

defmodule Examples.Authorization.AuditPrompt do
  @moduledoc false
  use MCP.Prompt, name: "audit"

  @impl true
  def render(_arguments, _context) do
    {:ok, MCP.Result.prompt_get(MCP.Prompt.message(:user, MCP.Prompt.text("Audit it.")))}
  end
end

defmodule Examples.Authorization.ReleaseNotes do
  @moduledoc false
  use MCP.Resource, uri: "demo://release-notes", name: "release_notes"

  @impl true
  def read(%{"uri" => uri}, _context) do
    {:ok, MCP.Result.resource_read(MCP.Resource.text(uri, "notes"))}
  end
end

defmodule Examples.Authorization.Policy do
  @moduledoc false
  @behaviour MCP.Authorization

  alias MCP.Authorization.Component

  # The library supplies the seam and the component identity. Roles, the
  # refusal code, the message, and the audit trail are all application-owned.
  @impl true
  def authorize(phase, %Component{} = component, context, options) do
    role = role(context)

    if component.name in Map.get(options.grants, role, []) do
      :ok
    else
      if phase == :invocation, do: send(options.audit, {:refused, role, component.name})

      {:error,
       MCP.Error.authorization(-32_003, "Role #{inspect(role)} may not use #{component.name}", %{
         "component" => component.name
       })}
    end
  end

  defp role(%MCP.Context{auth: %{"role" => role}}), do: role
  defp role(%MCP.Context{}), do: "anonymous"
end

defmodule Examples.Authorization.Server do
  @moduledoc false

  use MCP.Server,
    name: "authorization-example",
    version: "1.0.0",
    protocols: [MCP.Protocol.V2026_07_28],
    pagination: [page_size: 1]

  tool(Examples.Authorization.ReadPackage)
  tool(Examples.Authorization.PublishPackage)
  prompt(Examples.Authorization.AuditPrompt)
  resource(Examples.Authorization.ReleaseNotes)
end

defmodule Examples.Authorization.Runner do
  @moduledoc false

  @protocol "2026-07-28"

  @grants %{
    "maintainer" => ["read_package", "publish_package", "audit", "release_notes"],
    "reader" => ["read_package"]
  }

  def run(mode) do
    runtime =
      Examples.Authorization.Server.runtime(
        authorization: {Examples.Authorization.Policy, %{grants: @grants, audit: self()}}
      )

    # The page size is one, so the maintainer pages through its own catalog.
    maintainer = tool_names(runtime, "maintainer")
    reader = tool_names(runtime, "reader")
    anonymous = tool_names(runtime, nil)

    ensure(maintainer == ["publish_package", "read_package"], "the maintainer lost a page")
    ensure(reader == ["read_package"], "the reader saw a tool it may not use")
    ensure(anonymous == [], "an unauthenticated caller saw a catalog")

    guessed =
      dispatch(runtime, "reader", "tools/call", %{
        "name" => "publish_package",
        "arguments" => %{"version" => "1.0.0"}
      })

    ensure(guessed["error"]["code"] == -32_003, "a guessed call lost the application's error")
    ensure(Process.get(:published) == nil, "a refused call reached the handler")
    ensure_received({:refused, "reader", "publish_package"})

    ensure(
      dispatch(runtime, "reader", "prompts/get", %{"name" => "audit"})["error"]["code"] ==
        -32_003,
      "prompts/get did not share the policy"
    )

    ensure(
      dispatch(runtime, "reader", "resources/read", %{"uri" => "demo://release-notes"})["error"][
        "code"
      ] == -32_003,
      "resources/read did not share the policy"
    )

    cursor = dispatch(runtime, "maintainer", "tools/list")["result"]["nextCursor"]
    replayed = dispatch(runtime, "reader", "tools/list", %{"cursor" => cursor})

    ensure(
      replayed["error"]["message"] == "Pagination cursor has expired",
      "a cursor crossed two effective catalogs"
    )

    print_summary(mode)
  end

  defp tool_names(runtime, role, params \\ %{}) do
    result = dispatch(runtime, role, "tools/list", params)["result"]
    names = Enum.map(result["tools"], &Map.fetch!(&1, "name"))

    case result["nextCursor"] do
      nil -> names
      cursor -> names ++ tool_names(runtime, role, %{"cursor" => cursor})
    end
  end

  defp dispatch(runtime, role, method, params \\ %{}) do
    auth = if role, do: %{"role" => role}

    {:ok, response} =
      MCP.Test.dispatch(runtime,
        protocol: @protocol,
        method: method,
        params: params,
        transport_metadata: %{auth: auth}
      )

    response
  end

  defp ensure_received(message) do
    receive do
      ^message -> :ok
    after
      0 -> raise "the policy recorded no audit event for #{inspect(message)}"
    end
  end

  defp ensure(true, _message), do: :ok
  defp ensure(false, message), do: raise(message)

  defp print_summary(:check), do: IO.puts("23_authorization: ok")

  defp print_summary(:walkthrough) do
    IO.puts("One runtime served a maintainer, a reader, and an anonymous caller.")
    IO.puts("A guessed call kept the application's error, ran no handler, and was audited.")
    IO.puts("A cursor minted for one effective catalog expired against another.")
  end
end

case System.argv() do
  ["--check"] -> Examples.Authorization.Runner.run(:check)
  [] -> Examples.Authorization.Runner.run(:walkthrough)
  _arguments -> raise "usage: mix run examples/23_authorization.exs [--check]"
end
