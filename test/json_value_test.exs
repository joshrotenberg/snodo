defmodule MCP.JSONValueTest do
  use ExUnit.Case, async: true

  alias MCP.JSONValue

  doctest MCP.JSONValue

  defmodule Package do
    @moduledoc false
    defstruct [:name, :version, downloads: 0]
  end

  describe "valid?/1" do
    test "accepts the JSON value set" do
      assert JSONValue.valid?(nil)
      assert JSONValue.valid?(true)
      assert JSONValue.valid?(1)
      assert JSONValue.valid?(1.5)
      assert JSONValue.valid?("text")
      assert JSONValue.valid?([1, "two", nil])
      assert JSONValue.valid?(%{"a" => %{"b" => [1]}})
    end

    test "rejects atom keys and atom values" do
      refute JSONValue.valid?(%{a: 1})
      refute JSONValue.valid?(%{"a" => :b})
    end

    test "rejects structs, tuples, and pids" do
      refute JSONValue.valid?(~D[2026-08-29])
      refute JSONValue.valid?({1, 2})
      refute JSONValue.valid?(self())
    end
  end

  describe "encodable!/1" do
    test "converts atom keys and atom values" do
      assert JSONValue.encodable!(%{name: "jason", kind: :parser}) ==
               %{"name" => "jason", "kind" => "parser"}
    end

    test "leaves nil and booleans as themselves" do
      assert JSONValue.encodable!(%{a: nil, b: true, c: false}) ==
               %{"a" => nil, "b" => true, "c" => false}
    end

    test "recurses through lists and nested maps" do
      assert JSONValue.encodable!(%{items: [%{id: 1}, %{id: 2}]}) ==
               %{"items" => [%{"id" => 1}, %{"id" => 2}]}
    end

    test "renders date and time types in their canonical string form" do
      assert JSONValue.encodable!(%{
               date: ~D[2026-08-29],
               time: ~T[10:00:00],
               naive: ~N[2026-08-29 10:00:00],
               utc: ~U[2026-08-29 10:00:00Z]
             }) == %{
               "date" => "2026-08-29",
               "time" => "10:00:00",
               "naive" => "2026-08-29T10:00:00",
               "utc" => "2026-08-29T10:00:00Z"
             }
    end

    test "renders URI and Version as strings" do
      assert JSONValue.encodable!(%{url: URI.parse("https://hex.pm/packages/jason")}) ==
               %{"url" => "https://hex.pm/packages/jason"}

      assert JSONValue.encodable!(%{version: Version.parse!("1.4.4")}) ==
               %{"version" => "1.4.4"}
    end

    test "turns any other struct into a map of its fields" do
      assert JSONValue.encodable!(%Package{name: "jason", version: "1.4.4"}) ==
               %{"name" => "jason", "version" => "1.4.4", "downloads" => 0}
    end

    test "raises rather than silently dropping a colliding key" do
      colliding = %{"name" => "string key"} |> Map.put(:name, "atom key")

      assert_raise ArgumentError, ~r/two keys both become "name"/, fn ->
        JSONValue.encodable!(colliding)
      end
    end

    test "raises on terms with no correct JSON form" do
      assert_raise ArgumentError, fn -> JSONValue.encodable!({1, 2}) end
      assert_raise ArgumentError, fn -> JSONValue.encodable!(self()) end
      assert_raise ArgumentError, fn -> JSONValue.encodable!(make_ref()) end
      assert_raise ArgumentError, fn -> JSONValue.encodable!(fn -> :ok end) end
    end

    test "raises on a keyword list, which is a list of tuples" do
      assert_raise ArgumentError, ~r/cannot convert \{:sort, "name"\}/, fn ->
        JSONValue.encodable!(sort: "name")
      end
    end

    test "raises on a boolean used as a key" do
      assert_raise ArgumentError, ~r/as a JSON object key/, fn ->
        JSONValue.encodable!(%{true => 1})
      end
    end

    test "its output always satisfies valid?/1" do
      value = %{
        name: "jason",
        tags: [:json, :parser],
        released: ~D[2017-12-22],
        nested: %{count: 3, ok: true, missing: nil}
      }

      converted = JSONValue.encodable!(value)

      refute JSONValue.valid?(value)
      assert JSONValue.valid?(converted)
      assert is_binary(JSON.encode!(converted))
    end
  end

  describe "the boundary builders accept converted values" do
    test "MCP.Resource.json/3 takes an encodable! result" do
      value = JSONValue.encodable!(%{name: "jason", downloads: %{all: 1}})
      content = MCP.Resource.json("hex://jason/info", value)

      assert JSON.decode!(content["text"]) == %{"name" => "jason", "downloads" => %{"all" => 1}}
    end

    test "and rejects the unconverted value" do
      assert_raise ArgumentError, ~r/must be a JSON value/, fn ->
        MCP.Resource.json("hex://jason/info", %{name: "jason"})
      end
    end
  end
end
