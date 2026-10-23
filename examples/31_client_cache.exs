defmodule Examples.ClientCache.Server do
  @moduledoc false
  use Snodo.Server, name: "client-cache-example", version: "1.0.0"

  # Each read counts itself, so the example can tell a cached answer from a
  # fresh one. The result says it may be cached for five seconds by anyone.
  resource "rates", uri: "example://rates" do
    @impl true
    def read(%{"uri" => uri}, _context) do
      reads = :counters.get(:persistent_term.get(:example_cache_reads), 1) + 1
      :counters.add(:persistent_term.get(:example_cache_reads), 1, 1)

      {:ok,
       Snodo.Result.resource_read(Snodo.Resource.text(uri, "read #{reads}"),
         metadata: %{ttl_ms: 5_000, cache_scope: "public"}
       )}
    end
  end
end

defmodule Examples.ClientCache.Runner do
  @moduledoc false

  alias Examples.ClientCache.Server
  alias Snodo.Client

  def run(args) do
    check? = check_mode!(args)
    :persistent_term.put(:example_cache_reads, :counters.new(1, []))

    # The cache is off unless the client opts in.
    {:ok, client} = Client.direct(Server.runtime(), cache: true)

    {:ok, %{"contents" => [%{"text" => first}]}} = Client.read_resource(client, "example://rates")

    {:ok, %{"contents" => [%{"text" => second}]}} =
      Client.read_resource(client, "example://rates")

    ensure(first == "read 1" and second == "read 1", "second read served from the cache")

    {:ok, %{"contents" => [%{"text" => fresh}]}} =
      Client.read_resource(client, "example://rates", bypass_cache: true)

    ensure(fresh == "read 2", "bypass_cache reaches the server")

    # A client without the cache always asks the server.
    {:ok, uncached} = Client.direct(Server.runtime())

    {:ok, %{"contents" => [%{"text" => direct}]}} =
      Client.read_resource(uncached, "example://rates")

    ensure(direct == "read 3", "uncached client")

    if check? do
      IO.puts("31_client_cache: ok")
    else
      IO.puts("Two cached reads: #{first}, #{second}; bypassed: #{fresh}; uncached: #{direct}")
    end
  end

  defp ensure(true, _label), do: :ok
  defp ensure(false, label), do: raise("check failed: #{label}")

  defp check_mode!([]), do: false
  defp check_mode!(["--check"]), do: true

  defp check_mode!(_arguments),
    do: raise("usage: mix run examples/31_client_cache.exs [--check]")
end

Examples.ClientCache.Runner.run(System.argv())
