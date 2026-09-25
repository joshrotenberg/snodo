defmodule Snodo.Schema.Validator.BasicTest do
  use ExUnit.Case, async: true

  alias Snodo.Schema.Validator.Basic
  alias Snodo.Schema.Validator.Basic.Error

  test "validates nested object requirements and primitive types" do
    schema = %{
      "type" => "object",
      "required" => ["name", "settings"],
      "properties" => %{
        "name" => %{"type" => "string", "minLength" => 2},
        "settings" => %{
          "type" => "object",
          "required" => ["retries"],
          "properties" => %{"retries" => %{"type" => "integer", "minimum" => 0}}
        }
      }
    }

    assert Basic.validate(%{"name" => "mcp", "settings" => %{"retries" => 2}}, schema) == :ok

    assert {:error, %Error{path: ["settings", "retries"], keyword: "type", message: message}} =
             Basic.validate(%{"name" => "mcp", "settings" => %{"retries" => "two"}}, schema)

    assert message =~ "declared JSON types"

    assert {:error, %Error{path: ["settings", "retries"], keyword: "required"}} =
             Basic.validate(%{"name" => "mcp", "settings" => %{}}, schema)
  end

  test "supports arrays, recursive items, uniqueness, and size constraints" do
    schema = %{
      "type" => "array",
      "minItems" => 1,
      "maxItems" => 3,
      "uniqueItems" => true,
      "items" => %{"type" => "string", "pattern" => "^[a-z]+$"}
    }

    assert Basic.validate(["alpha", "beta"], schema) == :ok
    assert {:error, %Error{path: [], keyword: "minItems"}} = Basic.validate([], schema)
    assert {:error, %Error{path: [], keyword: "uniqueItems"}} = Basic.validate(["a", "a"], schema)
    assert {:error, %Error{path: [1], keyword: "pattern"}} = Basic.validate(["a", "B"], schema)

    assert {:error, %Error{path: [], keyword: "uniqueItems"}} =
             Basic.validate([1, 1.0], %{"type" => "array", "uniqueItems" => true})
  end

  test "supports numeric bounds, enum, const, and union types" do
    schema = %{
      "type" => ["integer", "null"],
      "minimum" => 1,
      "maximum" => 5,
      "enum" => [nil, 1, 2, 3, 4, 5]
    }

    assert Basic.validate(nil, schema) == :ok
    assert Basic.validate(3, schema) == :ok
    assert {:error, %Error{keyword: "enum"}} = Basic.validate(6, schema)
    assert {:error, %Error{keyword: "type"}} = Basic.validate("3", schema)
    assert Basic.validate(1.0, %{"const" => 1}) == :ok
  end

  test "rejects undeclared properties or validates them against an additional schema" do
    closed = %{
      "type" => "object",
      "properties" => %{"known" => %{"type" => "boolean"}},
      "additionalProperties" => false
    }

    assert Basic.validate(%{"known" => true}, closed) == :ok

    assert {:error, %Error{path: ["extra"], keyword: "additionalProperties"}} =
             Basic.validate(%{"known" => true, "extra" => 1}, closed)

    typed = %{"type" => "object", "additionalProperties" => %{"type" => "string"}}
    assert Basic.validate(%{"first" => "ok"}, typed) == :ok

    assert {:error, %Error{path: ["first"], keyword: "type"}} =
             Basic.validate(%{"first" => 1}, typed)
  end

  test "ignores unknown keywords so richer schemas can retain their wire shape" do
    schema = %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "type" => "object",
      "x-vendor" => %{"preserved" => true},
      "unevaluatedProperties" => false
    }

    assert Basic.validate(%{"anything" => true}, schema) == :ok
  end

  test "returns structured errors for malformed supported keywords" do
    assert {:error, %Error{path: [], keyword: "schema"}} = Basic.validate(%{}, [])

    assert {:error, %Error{path: [], keyword: "required"}} =
             Basic.validate(%{}, %{"type" => "object", "required" => "name"})

    assert {:error, %Error{path: [], keyword: "type"}} =
             Basic.validate(%{}, %{"type" => "made-up"})
  end
end
