defmodule Snodo.CompletionAcceptanceTest do
  use ExUnit.Case, async: true

  alias Snodo.Completion
  alias Snodo.Context
  alias Snodo.Error
  alias Snodo.Protocol.V2026_07_28
  alias Snodo.Result
  alias Snodo.Router
  alias Snodo.Transport.Context, as: TransportContext
  alias SnodoTest.TestCompletions.DeclaredError
  alias SnodoTest.TestCompletions.InvalidResult
  alias SnodoTest.TestCompletions.PackagePrompt
  alias SnodoTest.TestCompletions.Raising
  alias SnodoTest.TestCompletions.RepositoryTemplate
  alias SnodoTest.TestCompletions.WrongKind

  defp context do
    %Context{
      protocol_version: "2026-07-28",
      protocol: V2026_07_28,
      transport: %TransportContext{transport: :direct},
      request_id: "completion-direct"
    }
  end

  defp prompt_params(name, argument, value, arguments \\ %{}) do
    %{
      "ref" => %{"type" => "ref/prompt", "name" => name},
      "argument" => %{"name" => argument, "value" => value},
      "context" => %{"arguments" => arguments}
    }
  end

  defp resource_params(template, argument, value, arguments \\ %{}) do
    %{
      "ref" => %{"type" => "ref/resource", "uri" => template},
      "argument" => %{"name" => argument, "value" => value},
      "context" => %{"arguments" => arguments}
    }
  end

  test "normalizes and dispatches prompt completion through its owning module" do
    router = Router.new() |> Router.register_prompt(PackagePrompt)

    assert Router.completion_capable?(router)

    assert {:ok,
            %Result{
              kind: :completion,
              value: %{
                values: ["ecto", "ecto_sql"],
                total: 2,
                has_more: false
              }
            }} =
             Router.dispatch(
               router,
               :completion_complete,
               prompt_params("package_search", "name", "ec", %{"focus" => "health"}),
               context()
             )
  end

  test "resolves resource templates exactly and preserves contextual arguments" do
    router = Router.new() |> Router.register_resource(RepositoryTemplate)

    assert {:ok,
            %Result{
              kind: :completion,
              value: %{values: ["ecto", "ecto_sql"], total: 2}
            }} =
             Router.dispatch(
               router,
               :completion_complete,
               resource_params("repo://{owner}/{name}", "name", "ec", %{
                 "owner" => "elixir-ecto"
               }),
               context()
             )
  end

  test "rejects malformed references, undeclared arguments, and invalid prompt context" do
    router =
      Router.new()
      |> Router.register_prompt(PackagePrompt)
      |> Router.register_resource(RepositoryTemplate)

    cases = [
      prompt_params("missing", "name", "ec"),
      prompt_params("package_search", "unknown", "ec"),
      prompt_params("package_search", "name", "ec", %{"unknown" => "value"}),
      resource_params("repo://missing/{name}", "name", "ec"),
      %{"ref" => %{"type" => "ref/tool", "name" => "echo"}, "argument" => %{}},
      put_in(prompt_params("package_search", "name", "ec"), ["context", "arguments"], [])
    ]

    Enum.each(cases, fn params ->
      assert {:error, %Error{code: -32_602}} =
               Router.dispatch(router, :completion_complete, params, context())
    end)
  end

  test "declared errors survive while bad results and exceptions fail closed" do
    router =
      Router.new()
      |> Router.register_prompt(DeclaredError)
      |> Router.register_prompt(WrongKind)
      |> Router.register_prompt(InvalidResult)
      |> Router.register_prompt(Raising)

    assert {:error, %Error{code: -32_602, message: "Completion access denied"}} =
             Router.dispatch(
               router,
               :completion_complete,
               prompt_params("completion_declared_error", "value", ""),
               context()
             )

    for {name, message} <- [
          {"completion_wrong_kind", "Completion returned the wrong result kind"},
          {"completion_invalid_result", "Completion returned an invalid result"},
          {"completion_raising", "Completion raised an exception"}
        ] do
      assert {:error, %Error{code: -32_603, message: ^message}} =
               Router.dispatch(
                 router,
                 :completion_complete,
                 prompt_params(name, "value", ""),
                 context()
               )
    end
  end

  test "request and result validation enforce the bounded completion contract" do
    assert {:ok,
            %Completion{
              reference_type: :prompt,
              reference: "package_search",
              argument: "name",
              value: "ec",
              arguments: %{"focus" => "health"}
            }} =
             Completion.parse(
               prompt_params("package_search", "name", "ec", %{"focus" => "health"})
             )

    assert :ok = Completion.validate_result(Result.completion([], total: 0, has_more: false))

    assert {:error, :total_must_cover_returned_values} =
             Completion.validate_result(Result.completion(["one"], total: 0))

    assert {:error, :values_must_be_strings} =
             Completion.validate_result(Result.completion(["one", 2]))
  end

  test "compile-time declarations require owned arguments and completion callbacks" do
    assert_raise CompileError, ~r/unique names declared in arguments/, fn ->
      Code.compile_string("""
      defmodule SnodoTest.BadPromptCompletionArgument do
        use Snodo.Prompt,
          name: "bad_prompt_completion_argument",
          arguments: [%{"name" => "known"}],
          completion_arguments: ["unknown"]

        def render(_arguments, _context), do: {:ok, Snodo.Result.prompt_get([])}
      end
      """)
    end

    assert_raise CompileError, ~r/only resource templates may declare completion_arguments/, fn ->
      Code.compile_string("""
      defmodule SnodoTest.BadDirectResourceCompletion do
        use Snodo.Resource,
          uri: "test://bad-direct-completion",
          name: "bad_direct_completion",
          completion_arguments: ["value"]

        def read(%{"uri" => uri}, _context) do
          {:ok, Snodo.Result.resource_read(Snodo.Resource.text(uri, "bad"))}
        end
      end
      """)
    end

    [{module, _bytecode}] =
      Code.compile_string("""
      defmodule SnodoTest.MissingCompletionCallback do
        use Snodo.Prompt,
          name: "missing_completion_callback",
          arguments: [%{"name" => "value"}],
          completion_arguments: ["value"]

        def render(_arguments, _context), do: {:ok, Snodo.Result.prompt_get([])}
      end
      """)

    assert_raise ArgumentError, ~r/does not export complete\/2/, fn ->
      Router.register_prompt(Router.new(), module)
    end
  end
end
