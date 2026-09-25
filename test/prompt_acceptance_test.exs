defmodule SnodoTest.TestPrompts.PackageAnalysisCollision do
  use Snodo.Prompt,
    name: "package_analysis",
    description: "Collides with the package analysis fixture"

  @impl true
  def render(_arguments, _context), do: {:ok, Snodo.Result.prompt_get([])}
end

defmodule Snodo.PromptAcceptanceTest do
  use ExUnit.Case, async: true

  alias Snodo.Context
  alias Snodo.Error
  alias Snodo.Prompt
  alias Snodo.Prompt.Definition
  alias Snodo.Protocol.V2026_07_28
  alias Snodo.Result
  alias Snodo.Router
  alias Snodo.Transport.Context, as: TransportContext
  alias SnodoTest.TestPrompts.DeclaredError
  alias SnodoTest.TestPrompts.InvalidContent
  alias SnodoTest.TestPrompts.MediaReview
  alias SnodoTest.TestPrompts.PackageAnalysis
  alias SnodoTest.TestPrompts.PackageAnalysisCollision
  alias SnodoTest.TestPrompts.WrongKind

  defp context do
    %Context{
      protocol_version: "2026-07-28",
      protocol: V2026_07_28,
      transport: %TransportContext{transport: :direct},
      request_id: "prompt-1",
      metadata: %{"com.example/request" => %{"trace" => true}}
    }
  end

  test "prompt definitions preserve exact metadata and router listing is deterministic" do
    definition = PackageAnalysis.definition()

    assert %Definition{name: "package_analysis", title: "Analyze a Hex package"} = definition
    assert Enum.map(definition.arguments, & &1["name"]) == ["name", "focus"]

    assert Prompt.definition_to_map(definition)["_meta"] == %{
             "com.example/prompt" => %{"category" => "analysis"}
           }

    router =
      Router.new()
      |> Router.register_prompt(PackageAnalysis)
      |> Router.register_prompt(MediaReview)
      |> Router.register_prompt(PackageAnalysis)

    assert Enum.map(Router.list_prompts(router), & &1.name) == [
             "media_review",
             "package_analysis"
           ]

    assert_raise ArgumentError, ~r/prompt name "package_analysis" is already registered/, fn ->
      Router.register_prompt(router, PackageAnalysisCollision)
    end
  end

  test "prompt arguments are flat strings and required arguments fail before rendering" do
    router = Router.new() |> Router.register_prompt(PackageAnalysis)

    assert {:error, %Error{code: -32_602, data: %{"missing" => ["name"]}}} =
             Router.dispatch(router, {:prompt_get, "package_analysis"}, %{}, context())

    assert {:error,
            %Error{code: -32_602, message: "Prompt arguments must map strings to strings"}} =
             Router.dispatch(
               router,
               {:prompt_get, "package_analysis"},
               %{"arguments" => %{"name" => 7}},
               context()
             )

    assert {:error, %Error{code: -32_602, message: "Unknown prompt: missing"}} =
             Router.dispatch(router, {:prompt_get, "missing"}, %{}, context())
  end

  test "rendering returns multi-turn messages and preserves protocol-neutral metadata" do
    router = Router.new() |> Router.register_prompt(PackageAnalysis)

    assert {:ok,
            %Result{
              kind: :prompt_get,
              value: %{description: "Analysis workflow for plug", messages: messages},
              metadata: metadata
            }} =
             Router.dispatch(
               router,
               {:prompt_get, "package_analysis"},
               %{"arguments" => %{"name" => "plug", "focus" => "security"}},
               context()
             )

    assert Enum.map(messages, & &1["role"]) == ["user", "assistant"]
    assert get_in(hd(messages), ["content", "text"]) == "Analyze plug, focusing on security."

    assert metadata == %{
             "com.example/result" => %{
               "requestId" => "prompt-1",
               "request" => %{"trace" => true}
             }
           }
  end

  test "content builders cover image, audio, embedded resources, and resource links" do
    router = Router.new() |> Router.register_prompt(MediaReview)

    assert {:ok, %Result{value: %{messages: messages}}} =
             Router.dispatch(
               router,
               {:prompt_get, "media_review"},
               %{"arguments" => %{"uri" => "test://package/plug"}},
               context()
             )

    assert Enum.map(messages, &get_in(&1, ["content", "type"])) == [
             "image",
             "audio",
             "resource",
             "resource_link"
           ]

    assert get_in(Enum.at(messages, 2), ["content", "resource", "text"]) ==
             "embedded package notes"

    assert get_in(Enum.at(messages, 3), ["content", "uri"]) == "test://package/plug"
  end

  test "invalid content, wrong result kinds, and declared errors stay on safe boundaries" do
    router =
      Router.new()
      |> Router.register_prompt(DeclaredError)
      |> Router.register_prompt(InvalidContent)
      |> Router.register_prompt(WrongKind)

    assert {:error, %Error{code: -32_602, message: "Prompt access denied"}} =
             Router.dispatch(router, {:prompt_get, "declared_error"}, %{}, context())

    assert {:error, %Error{code: -32_603, message: "Prompt raised an exception"}} =
             Router.dispatch(router, {:prompt_get, "invalid_content"}, %{}, context())

    assert {:error, %Error{code: -32_603, message: "Prompt returned the wrong result kind"}} =
             Router.dispatch(router, {:prompt_get, "wrong_kind"}, %{}, context())
  end

  test "definition and content validation reject malformed static data" do
    assert_raise CompileError, ~r/prompt argument names must be unique/, fn ->
      Code.compile_string("""
      defmodule SnodoTest.BadDuplicatePromptArguments do
        use Snodo.Prompt,
          name: "bad_duplicate",
          arguments: [%{"name" => "same"}, %{"name" => "same"}]

        def render(_arguments, _context), do: {:ok, Snodo.Result.prompt_get([])}
      end
      """)
    end

    assert_raise ArgumentError, ~r/must be valid base64/, fn ->
      Prompt.image("not-base64", "image/png")
    end

    assert_raise ArgumentError, ~r/requires a user\/assistant role/, fn ->
      Prompt.validate_message!(%{"role" => "system", "content" => Prompt.text("no")})
    end
  end
end
