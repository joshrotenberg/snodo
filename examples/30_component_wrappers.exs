defmodule Examples.Wrappers.Audit do
  @moduledoc false
  # A custom wrapper: it sees the request context and arguments, calls the
  # next wrapper or the callback, and can change or replace the result.
  @behaviour Snodo.Component.Wrap

  @impl true
  def call(context, arguments, next, options) do
    send(context.auth[:observer], {:audit, Keyword.fetch!(options, :label), arguments})
    next.(context, arguments)
  end
end

defmodule Examples.Wrappers.Server do
  @moduledoc false
  use Snodo.Server, name: "wrappers-example", version: "1.0.0"

  # The first wrapper runs outermost. The rate limit keys on the principal the
  # transport assigned, so each caller has its own bucket.
  tool "lookup",
    wrap: [
      {Examples.Wrappers.Audit, label: :lookup},
      {Snodo.Component.Wrap.Timeout, timeout: 500},
      {Snodo.Component.Wrap.RateLimit,
       limit: 1, window_ms: 60_000, key: fn context -> context.auth[:principal] end}
    ] do
    argument("query", :string, required: true)

    @impl true
    def call(%{"query" => query}, _context), do: {:ok, "found #{query}"}
  end

  tool "slow", wrap: [{Snodo.Component.Wrap.Timeout, timeout: 50}] do
    @impl true
    def call(_arguments, _context) do
      Process.sleep(1_000)
      {:ok, "unreachable"}
    end
  end
end

defmodule Examples.Wrappers.Runner do
  @moduledoc false

  alias Examples.Wrappers.Server
  alias Snodo.Client

  def run(args) do
    check? = check_mode!(args)

    {:ok, alice} = Client.direct(Server.runtime(), auth: %{principal: "alice", observer: self()})
    {:ok, bob} = Client.direct(Server.runtime(), auth: %{principal: "bob", observer: self()})

    {:ok, %{"content" => [%{"text" => "found docs"}]}} =
      Client.call_tool(alice, "lookup", %{"query" => "docs"})

    receive do
      {:audit, :lookup, %{"query" => "docs"}} -> :ok
    after
      1_000 -> raise "the audit wrapper did not run"
    end

    # Alice's second call is over her limit of one; Bob has his own bucket.
    {:ok, %{"isError" => true, "content" => [%{"text" => limited}]}} =
      Client.call_tool(alice, "lookup", %{"query" => "again"})

    ensure(limited =~ "rate limit", "per-principal limit")

    {:ok, %{"content" => [%{"text" => "found docs"}]}} =
      Client.call_tool(bob, "lookup", %{"query" => "docs"})

    {:ok, %{"isError" => true, "content" => [%{"text" => timed_out}]}} =
      Client.call_tool(alice, "slow")

    ensure(timed_out =~ "timed out", "timeout")

    if check? do
      IO.puts("30_component_wrappers: ok")
    else
      IO.puts("Second call for alice: #{limited}")
      IO.puts("Slow tool: #{timed_out}")
    end
  end

  defp ensure(true, _label), do: :ok
  defp ensure(false, label), do: raise("check failed: #{label}")

  defp check_mode!([]), do: false
  defp check_mode!(["--check"]), do: true

  defp check_mode!(_arguments),
    do: raise("usage: mix run examples/30_component_wrappers.exs [--check]")
end

Examples.Wrappers.Runner.run(System.argv())
