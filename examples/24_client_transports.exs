defmodule Examples.ClientTransports.Greet do
  @moduledoc false

  use MCP.Tool,
    name: "greet",
    description: "Create a greeting"

  input_schema(%{
    "type" => "object",
    "properties" => %{"name" => %{"type" => "string"}},
    "required" => ["name"],
    "additionalProperties" => false
  })

  @impl true
  def call(%{"name" => name}, _context), do: {:ok, MCP.Result.text("Hello, #{name}!")}
end

defmodule Examples.ClientTransports.Server do
  @moduledoc false

  use MCP.Server,
    name: "client-transports-example",
    version: "0.1.0",
    protocols: [MCP.Protocol.V2026_07_28]

  tool(Examples.ClientTransports.Greet)
end

# The same client calls against one server three ways: in process, as a stdio
# subprocess (this script started again with --serve-stdio), and over the
# native Streamable HTTP listener.
defmodule Examples.ClientTransports.Runner do
  @moduledoc false

  alias Examples.ClientTransports.Server
  alias MCP.Client
  alias MCP.Transport.StreamableHTTP.Server, as: HTTPServer

  @expected {"Hello, Ada!", -32_602}

  def run(["--serve-stdio"]) do
    :ok = MCP.Transport.Stdio.serve(Server.runtime())
  end

  def run(args) do
    check? = check_mode!(args)
    {:ok, listener} = HTTPServer.start_link(runtime: Server.runtime(), port: 0)

    results =
      try do
        for {label, connect} <- targets(HTTPServer.url(listener)) do
          {:ok, client} = connect.()

          try do
            {label, exercise(client)}
          after
            Client.close(client)
          end
        end
      after
        GenServer.stop(listener)
      end

    for {label, result} <- results, result != @expected do
      raise "#{label} returned #{inspect(result)}, expected #{inspect(@expected)}"
    end

    if check? do
      IO.puts("24_client_transports: ok")
    else
      print_walkthrough(results)
    end
  end

  defp targets(url) do
    elixir = System.find_executable("elixir") || raise "elixir executable was not found"
    ebin = MCP.Client |> :code.which() |> List.to_string() |> Path.dirname()

    [
      direct: fn -> Client.direct(Server.runtime()) end,
      stdio: fn ->
        Client.connect({:stdio, elixir, ["-pa", ebin, __ENV__.file, "--serve-stdio"]})
      end,
      http: fn -> Client.connect({:http, url}) end
    ]
  end

  defp exercise(client) do
    {:ok, [%{"name" => "greet"}]} = Client.list_tools(client)

    {:ok, %{"content" => [%{"type" => "text", "text" => text}]}} =
      Client.call_tool(client, "greet", %{"name" => "Ada"})

    {:error, %MCP.Error{code: code}} = Client.call_tool(client, "missing")
    {text, code}
  end

  defp print_walkthrough(results) do
    IO.puts("One MCP.Client API over three transports:\n")

    for {label, {text, code}} <- results do
      IO.puts("  #{label}: greet -> #{inspect(text)}, unknown tool -> #{code}")
    end
  end

  defp check_mode!([]), do: false
  defp check_mode!(["--check"]), do: true

  defp check_mode!(_arguments),
    do: raise("usage: mix run examples/24_client_transports.exs [--check]")
end

Examples.ClientTransports.Runner.run(System.argv())
