defmodule Examples.ServerLogging.Server do
  @moduledoc false
  use Snodo.Server,
    name: "server-logging-example",
    version: "1.0.0",
    capabilities: %{"tools" => %{}, "logging" => %{}}

  tool "import", description: "Imports rows and logs its progress" do
    @impl true
    def call(_arguments, context) do
      :ok = Snodo.Logging.log(context, :info, "Import started", logger: "importer")
      :ok = Snodo.Logging.log(context, :debug, %{"rows" => 120})
      :ok = Snodo.Logging.log(context, :warning, "3 rows skipped", logger: "importer")
      {:ok, "Imported 117 rows"}
    end
  end
end

defmodule Examples.ServerLogging.Runner do
  @moduledoc false

  alias Examples.ServerLogging.Server
  alias Snodo.Client

  def run(args) do
    check? = check_mode!(args)

    # 2026-07-28: the client asks for a level on each request.
    {:ok, client} = Client.direct(Server.runtime(), on_log: self(), log_level: :info)
    {:ok, _result} = Client.call_tool(client, "import")
    ensure(levels() == ["info", "warning"], "messages at or above :info")

    {:ok, _result} = Client.call_tool(client, "import", %{}, log_level: :debug)
    ensure(levels() == ["info", "debug", "warning"], "a per-request level")

    # Without a level, a 2026-07-28 server sends no messages.
    {:ok, _result} = Client.call_tool(client, "import", %{}, log_level: nil)
    ensure(levels() == [], "no level, no messages")

    # An initialize-era client that has not called logging/setLevel gets the
    # runtime's :log_level, :info unless set.
    runtime =
      Server.runtime(protocols: [Snodo.Protocol.V2025_11_25], log_level: :warning)

    {:ok, legacy} = Client.direct(runtime, on_log: self())
    {:ok, _result} = Client.call_tool(legacy, "import")
    ensure(levels() == ["warning"], "the runtime's level")

    if check? do
      IO.puts("34_server_logging: ok")
    else
      IO.puts("2026-07-28 at :info logged info and warning; with no level, nothing")
      IO.puts("2025-11-25 with log_level: :warning logged warning")
    end
  end

  defp levels do
    receive do
      {:snodo_log, %{"level" => level}} -> [level | levels()]
    after
      0 -> []
    end
  end

  defp ensure(true, _label), do: :ok
  defp ensure(false, label), do: raise("check failed: #{label}")

  defp check_mode!([]), do: false
  defp check_mode!(["--check"]), do: true

  defp check_mode!(_arguments),
    do: raise("usage: mix run examples/34_server_logging.exs [--check]")
end

Examples.ServerLogging.Runner.run(System.argv())
