project = Path.expand("../..", __DIR__)
ebin = System.get_env("SNODO_EBIN") || Path.join(project, "_build/dev/lib/snodo/ebin")
true = Code.prepend_path(ebin)
{:ok, _applications} = Application.ensure_all_started(:snodo)

defmodule OfficialPython.Echo do
  @moduledoc false
  use Snodo.Tool.Simple, name: "echo", description: "Echo a string"
  argument("text", :string, required: true)

  @impl true
  def call(%{"text" => text}, _context), do: {:ok, Snodo.Result.text(text)}
end

defmodule OfficialPython.Resource do
  @moduledoc false
  use Snodo.Resource, uri: "interop://greeting", name: "Greeting", mime_type: "text/plain"

  @impl true
  def read(%{"uri" => uri}, _context),
    do: {:ok, Snodo.Result.resource_read(Snodo.Resource.text(uri, "hello from snodo"))}
end

defmodule OfficialPython.Prompt do
  @moduledoc false
  use Snodo.Prompt,
    name: "greet",
    description: "Greet a name",
    arguments: [
      %{"name" => "name", "required" => true}
    ]

  @impl true
  def render(%{"name" => name}, _context),
    do:
      {:ok,
       Snodo.Result.prompt_get(Snodo.Prompt.message(:user, Snodo.Prompt.text("Hello, #{name}")))}
end

defmodule OfficialPython.Elicit do
  @moduledoc false
  # On an initialize-era session the input request reaches the client as an
  # elicitation/create request, and the answer comes back as inputResponses.
  use Snodo.Tool, name: "elicit", description: "Ask the user for a name"

  @impl true
  def call(_arguments, context) do
    request =
      Snodo.Elicitation.form("Your name?", %{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string"}},
        "required" => ["name"]
      })

    case Snodo.Elicitation.response(context, "name", request) do
      :missing -> {:ok, Snodo.Result.input_required(input_requests: %{"name" => request})}
      {:ok, %{"content" => %{"name" => name}}} -> {:ok, Snodo.Result.text("Hello, #{name}")}
      {:ok, %{"action" => action}} -> {:ok, Snodo.Result.text(action)}
    end
  end
end

defmodule OfficialPython.Sample do
  @moduledoc false
  use Snodo.Tool, name: "sample", description: "Ask the client to sample a reply"

  @impl true
  def call(_arguments, context) do
    request =
      Snodo.Sampling.create_message(
        [Snodo.Prompt.message(:user, Snodo.Prompt.text("Say something"))],
        max_tokens: 20
      )

    case Snodo.Sampling.response(context, "reply", request) do
      :missing ->
        {:ok, Snodo.Result.input_required(input_requests: %{"reply" => request})}

      {:ok, %{"model" => model, "content" => %{"text" => text}}} ->
        {:ok, Snodo.Result.text("#{model}: #{text}")}
    end
  end
end

{argv, sessions} =
  case System.argv() do
    [transport, version, "--sessions"] -> {[transport, version], true}
    argv -> {argv, false}
  end

case argv do
  [transport, version] when transport in ["--stdio", "--http"] ->
    protocol =
      case version do
        "2026-07-28" -> Snodo.Protocol.V2026_07_28
        "2025-11-25" -> Snodo.Protocol.V2025_11_25
        "2025-06-18" -> Snodo.Protocol.V2025_06_18
        _other -> raise "unknown protocol version"
      end

    router =
      Snodo.Router.new()
      |> Snodo.Router.register_tool(OfficialPython.Echo)
      |> Snodo.Router.register_resource(OfficialPython.Resource)
      |> Snodo.Router.register_prompt(OfficialPython.Prompt)
      |> then(fn router ->
        if sessions,
          do:
            router
            |> Snodo.Router.register_tool(OfficialPython.Elicit)
            |> Snodo.Router.register_tool(OfficialPython.Sample),
          else: router
      end)

    runtime =
      Snodo.Server.Runtime.new(
        router: router,
        protocols: [protocol],
        server_info: %{"name" => "python-interop", "version" => "1.0.0"}
      )

    case transport do
      "--stdio" ->
        :ok = Snodo.Transport.Stdio.serve(runtime, sessions: sessions)

      "--http" ->
        {:ok, listener} =
          Snodo.Transport.StreamableHTTP.Server.start_link(
            runtime: runtime,
            port: 0,
            sessions: sessions
          )

        IO.puts(JSON.encode!(%{"url" => Snodo.Transport.StreamableHTTP.Server.url(listener)}))
        _input = IO.read(:stdio, :eof)
        :ok = GenServer.stop(listener)
    end

  _arguments ->
    raise "usage: elixir fixture.exs --stdio|--http VERSION [--sessions]"
end
