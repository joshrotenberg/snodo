defmodule Snodo.ProxyTest.StdioLoggingBackend do
  use Snodo.Server,
    name: "proxy-stdio-logging-backend",
    version: "1.0.0",
    capabilities: %{"tools" => %{}, "logging" => %{}}

  tool "log" do
    argument("port", :integer, required: true)
    argument("name", :string, required: true)
    argument("level", :string, required: true)

    @impl true
    def call(%{"port" => port, "name" => name, "level" => level}, context) do
      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, name)
      {:ok, "release"} = :gen_tcp.recv(socket, 7, 5_000)
      :ok = :gen_tcp.close(socket)
      :ok = Snodo.Logging.log(context, Snodo.Logging.parse_level(level), name, logger: "barrier")
      {:ok, name}
    end
  end
end

:ok = Snodo.Transport.Stdio.serve(Snodo.ProxyTest.StdioLoggingBackend.runtime())
