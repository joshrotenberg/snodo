defmodule Snodo.ResultTest do
  use ExUnit.Case, async: true

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
