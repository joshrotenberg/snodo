Code.require_file("support/mrtr_elicitation.exs", __DIR__)

defmodule Examples.MRTR.Runner do
  @moduledoc false

  def run(mode) do
    Examples.MRTR.Workflow.configure()
    runtime = Examples.MRTR.Server.runtime()
    params = %{"name" => "preference_preview", "arguments" => %{"subject" => "example"}}
    first = dispatch(runtime, 1, params)
    %{"resultType" => "input_required", "requestState" => token} = first

    second =
      dispatch(
        runtime,
        2,
        Map.merge(params, %{
          "requestState" => token,
          "inputResponses" => %{
            "color" => %{"action" => "accept", "content" => %{"color" => "blue"}}
          }
        })
      )

    %{"resultType" => "input_required", "requestState" => next_token} = second
    if token == next_token, do: raise("continuation state was not replaced")

    final =
      dispatch(
        runtime,
        3,
        Map.merge(params, %{
          "requestState" => next_token,
          "inputResponses" => %{
            "style" => %{"action" => "accept", "content" => %{"style" => "compact"}}
          }
        })
      )

    %{"content" => [%{"text" => json}]} = final
    %{"color" => "blue", "style" => "compact", "status" => "preview"} = JSON.decode!(json)

    case mode do
      :check ->
        IO.puts("20_mrtr_elicitation: ok")

      :walkthrough ->
        IO.puts("Two elicitation rounds produced a read-only preview: #{json}")
        IO.puts("Each retry used a fresh request ID and signed, operation-bound state.")

        IO.puts(
          "The same workflow also serves a resource and prompt; see the official-client MRTR check."
        )
    end
  end

  defp dispatch(runtime, id, params) do
    {:ok, %{"result" => result}} =
      Snodo.Test.dispatch(runtime,
        id: id,
        method: "tools/call",
        protocol: "2026-07-28",
        params: params,
        client_capabilities: %{"elicitation" => %{"form" => %{}, "url" => %{}}}
      )

    result
  end
end

case System.argv() do
  ["--check"] -> Examples.MRTR.Runner.run(:check)
  [] -> Examples.MRTR.Runner.run(:walkthrough)
  _arguments -> raise "usage: mix run examples/20_mrtr_elicitation.exs [--check]"
end
