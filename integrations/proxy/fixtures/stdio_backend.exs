defmodule Snodo.ProxyTest.StdioBackend do
  use Snodo.Server, name: "proxy-stdio-backend", version: "1.0.0"

  tool "echo" do
    argument("text", :string, required: true)

    @impl true
    def call(%{"text" => text}, _context), do: {:ok, text}
  end
end

:ok = Snodo.Transport.Stdio.serve(Snodo.ProxyTest.StdioBackend.runtime())
