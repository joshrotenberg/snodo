defmodule Snodo.ResultTest do
  use ExUnit.Case, async: true

  alias Snodo.Protocol.{V2025_06_18, V2025_11_25, V2026_07_28}
  alias Snodo.Result
  alias SnodoTest.TestFixtures

  defmodule Picture do
    use Snodo.Tool, name: "picture"

    @impl true
    def call(_arguments, _context) do
      {:ok,
       Result.content([
         %{"type" => "image", "data" => "iVBORw0KGgo=", "mimeType" => "image/png"},
         %{"type" => "text", "text" => "a caption"}
       ])}
    end
  end

  defmodule Raw do
    use Snodo.Tool, name: "raw"

    @impl true
    def call(arguments, _context), do: {:ok, Result.raw(arguments)}
  end

  test "raw tool results fill missing content in all supported dialects" do
    protocols = [V2026_07_28, V2025_11_25, V2025_06_18]
    runtime = TestFixtures.runtime(tools: [Raw], protocols: protocols)
    value = %{"items" => [1, "two"]}
    fallback = [%{"type" => "text", "text" => JSON.encode!(value)}]
    explicit = [%{"type" => "text", "text" => "custom text"}]

    for protocol <- protocols do
      for {arguments, expected} <- [
            {%{"structuredContent" => value}, fallback},
            {%{"isError" => true, "structuredContent" => value}, fallback},
            {%{"structuredContent" => value, "content" => []}, []},
            {%{"structuredContent" => value, "content" => explicit}, explicit},
            {%{}, []}
          ] do
        assert {:ok, %{"result" => %{"content" => ^expected, "isError" => is_error} = result}} =
                 Snodo.Test.dispatch(runtime,
                   protocol: protocol.version(),
                   method: "tools/call",
                   params: %{"name" => "raw", "arguments" => arguments}
                 )

        assert is_error == Map.get(arguments, "isError", false)
        assert Map.fetch(result, "structuredContent") == Map.fetch(arguments, "structuredContent")
      end
    end
  end

  test "content/2 sends the given content blocks as a tools/call result" do
    runtime = TestFixtures.runtime(tools: [Picture])

    assert {:ok, %{"result" => result}} =
             Snodo.Test.dispatch(runtime,
               protocol: "2026-07-28",
               method: "tools/call",
               params: %{"name" => "picture", "arguments" => %{}}
             )

    assert result["isError"] == false

    assert [%{"type" => "image", "mimeType" => "image/png"}, %{"type" => "text"}] =
             result["content"]
  end

  test "resource/2 is deprecated in favor of content/2" do
    assert {{:resource, 2}, message} =
             List.keyfind(Result.__info__(:deprecated), {:resource, 2}, 0)

    assert message =~ "content/2"
  end
end
