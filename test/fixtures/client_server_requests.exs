# A hand-written stdio server for Snodo.Client tests that sends requests to
# the client as soon as it starts, without any handshake. Run it as
#   elixir test/fixtures/client_server_requests.exs [--elicit N] [--no-ping]
#
# What the tests rely on:
#
#   * At start it writes a `ping` request (id "srv-ping"), unless --no-ping
#     is given, and then N form `elicitation/create` requests (ids "srv-1" to
#     "srv-N"), N defaulting to 1.
#   * Every request from the client waits until the client has answered
#     `params["waitFor"]` of those, all of them by default, then gets a result
#     `%{"answers" => answers}`, where `answers` maps each request id to the
#     response the client sent for it.
#   * It exits at EOF.

defmodule ServerRequestsFixture do
  @moduledoc false

  def main(args) do
    count = args |> option("--elicit", "1") |> String.to_integer()
    ping? = "--no-ping" not in args
    ids = if(ping?, do: ["srv-ping"], else: []) ++ Enum.map(1..count//1, &"srv-#{&1}")

    if ping?, do: write(%{"jsonrpc" => "2.0", "id" => "srv-ping", "method" => "ping"})

    for n <- 1..count//1 do
      write(%{
        "jsonrpc" => "2.0",
        "id" => "srv-#{n}",
        "method" => "elicitation/create",
        "params" => %{
          "mode" => "form",
          "message" => "Your name?",
          "requestedSchema" => %{
            "type" => "object",
            "properties" => %{"name" => %{"type" => "string"}}
          }
        }
      })
    end

    loop(%{expected: length(ids), answers: %{}, waiting: []})
  end

  defp option(args, name, default) do
    case Enum.drop_while(args, &(&1 != name)) do
      [^name, value | _rest] -> value
      _absent -> default
    end
  end

  defp loop(state) do
    case IO.binread(:stdio, :line) do
      :eof -> :ok
      {:error, _reason} -> :ok
      line -> line |> String.trim() |> JSON.decode!() |> handle(state) |> flush() |> loop()
    end
  end

  defp handle(%{"id" => id, "method" => _method} = request, state) do
    need = get_in(request, ["params", "waitFor"]) || state.expected
    %{state | waiting: state.waiting ++ [{id, need}]}
  end

  defp handle(%{"id" => id} = answer, state),
    do: %{state | answers: Map.put(state.answers, id, answer)}

  defp handle(_notification, state), do: state

  defp flush(%{answers: answers} = state) do
    {ready, waiting} =
      Enum.split_with(state.waiting, fn {_id, need} -> map_size(answers) >= need end)

    for {id, _need} <- ready do
      write(%{"jsonrpc" => "2.0", "id" => id, "result" => %{"answers" => answers}})
    end

    %{state | waiting: waiting}
  end

  defp write(message), do: IO.binwrite(:stdio, JSON.encode!(message) <> "\n")
end

ServerRequestsFixture.main(System.argv())
