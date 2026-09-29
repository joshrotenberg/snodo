defmodule Snodo.RootsTest do
  use ExUnit.Case, async: true

  alias Snodo.Error
  alias Snodo.Roots

  test "the builder returns a bare embedded request with empty params" do
    assert Roots.list() == %{"method" => "roots/list", "params" => %{}}
    assert Roots.validate_request(Roots.list()) == :ok
  end

  test "params are optional and carry at most _meta, and the request stays bare" do
    assert Roots.validate_request(%{"method" => "roots/list"}) == :ok

    assert Roots.validate_request(%{"method" => "roots/list", "params" => %{"_meta" => %{}}}) ==
             :ok

    for request <- [
          %{"method" => "roots/list", "params" => %{"cursor" => "x"}},
          %{"method" => "roots/list", "params" => %{"_meta" => []}},
          %{"method" => "roots/list", "params" => %{"_meta" => %{}, "cursor" => "x"}},
          %{"method" => "roots/list", "params" => []},
          %{"method" => "roots/list", "params" => %{}, "id" => 1},
          %{"method" => "roots/list", "params" => %{}, "jsonrpc" => "2.0"},
          %{"method" => "roots/list/all"},
          %{"method" => "elicitation/create", "params" => %{}},
          %{},
          nil
        ] do
      assert {:error, _message} = Roots.validate_request(request)
    end
  end

  test "capability checks require a roots object" do
    for capabilities <- [%{}, %{"roots" => nil}, %{"roots" => true}, %{"sampling" => %{}}] do
      refute Roots.supported?(Roots.list(), capabilities)
    end

    assert Roots.supported?(Roots.list(), %{"roots" => %{}})
    assert Roots.supported?(%{"method" => "roots/list"}, %{"roots" => %{"listChanged" => true}})

    refute Roots.supported?(%{"method" => "roots/list", "params" => %{"a" => 1}}, %{
             "roots" => %{}
           })

    refute Roots.supported?(%{}, %{"roots" => %{}})
    assert Roots.required_capability(Roots.list()) == {"roots", %{}}
  end

  test "responses are read by ID and unrelated responses are ignored" do
    context = %{input_responses: %{"unrelated" => %{"bogus" => "not a roots response"}}}
    assert Roots.response(context, "client_roots", Roots.list()) == :missing
    assert Roots.response(%{}, "client_roots", Roots.list()) == :missing

    roots = %{"roots" => [%{"uri" => "file:///work", "name" => "Work"}]}
    context = put_in(context, [:input_responses, "client_roots"], roots)
    assert Roots.response(context, "client_roots", Roots.list()) == {:ok, roots}
  end

  test "valid responses list file roots with optional names, keeping unknown fields" do
    for roots <- [
          [],
          [%{"uri" => "file:///work"}],
          [%{"uri" => "file:///work", "name" => "Work", "_meta" => %{"com.example/x" => 1}}],
          [%{"uri" => "file:///a"}, %{"uri" => "file:///b", "name" => "B"}],
          [%{"uri" => "file:///work", "future" => true}]
        ] do
      result = %{"roots" => roots, "future" => %{"field" => true}}
      assert reply(result) == {:ok, result}
    end
  end

  test "invalid consumed responses return generic invalid params without submitted contents" do
    for result <- [
          nil,
          %{},
          %{"roots" => %{}},
          %{"roots" => [nil]},
          %{"roots" => [%{"name" => "no uri"}]},
          %{"roots" => [%{"uri" => "https://example.test/"}]},
          %{"roots" => [%{"uri" => "/work"}]},
          %{"roots" => [%{"uri" => "file:///work with space"}]},
          %{"roots" => [%{"uri" => "file:///work", "name" => 1}]},
          %{"roots" => [%{"uri" => "file:///work", "_meta" => []}]},
          %{"roots" => [%{"uri" => "file:///work", "extra" => :atom}]},
          %{"result" => %{"roots" => []}}
        ] do
      assert_invalid(reply(result))
    end

    assert_invalid(Roots.response(%{input_responses: []}, "client_roots", Roots.list()))
    assert_invalid(Roots.response(nil, "client_roots", Roots.list()))

    # A response cannot be consumed through a request the dialect would refuse.
    bad_request = %{"method" => "roots/list", "params" => %{"a" => 1}}
    context = %{input_responses: %{"client_roots" => %{"roots" => []}}}
    assert_invalid(Roots.response(context, "client_roots", bad_request))
  end

  defp reply(result),
    do:
      Roots.response(
        %{input_responses: %{"client_roots" => result}},
        "client_roots",
        Roots.list()
      )

  defp assert_invalid(result) do
    assert {:error,
            %Error{code: -32_602, message: "Invalid roots response", data: nil, cause: nil}} =
             result
  end
end
