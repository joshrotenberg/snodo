defmodule Snodo.Schema.Validator.JSVTest do
  use ExUnit.Case, async: true

  alias Snodo.Schema.Validator.JSV, as: Validator
  alias Snodo.Schema.Validator.JSV.BuildError
  alias Snodo.Schema.Validator.JSV.Compiled

  @draft202012 "https://json-schema.org/draft/2020-12/schema"
  @draft7 "http://json-schema.org/draft-07/schema#"

  test "validates composition and conditional branches beyond Basic's subset" do
    schema = %{
      "type" => "object",
      "required" => ["kind", "value"],
      "properties" => %{"kind" => %{"enum" => ["count", "label"]}},
      "allOf" => [
        %{
          "if" => %{"properties" => %{"kind" => %{"const" => "count"}}},
          "then" => %{"properties" => %{"value" => %{"type" => "integer"}}},
          "else" => %{"properties" => %{"value" => %{"type" => "string"}}}
        },
        %{"not" => %{"properties" => %{"value" => %{"const" => 0}}}}
      ]
    }

    assert Validator.validate(%{"kind" => "count", "value" => 2}, schema) == :ok
    assert Validator.validate(%{"kind" => "label", "value" => "two"}, schema) == :ok

    assert {:error, %JSV.ValidationError{}} =
             Validator.validate(%{"kind" => "count", "value" => "2"}, schema)

    assert {:error, _} = Validator.validate(%{"kind" => "count", "value" => 0}, schema)

    exclusive = %{"oneOf" => [%{"type" => "integer"}, %{"type" => "number"}]}
    assert {:error, _} = Validator.validate(2, exclusive)
    assert Validator.validate(2.5, exclusive) == :ok

    assert Validator.validate(nil, %{"anyOf" => [%{"type" => "string"}, %{"type" => "null"}]}) ==
             :ok
  end

  test "compiles once for repeated validation and preserves the raw schema" do
    schema = %{
      "$schema" => @draft202012,
      "$defs" => %{"name" => %{"type" => "string", "minLength" => 2}},
      "$ref" => "#/$defs/name",
      "x-vendor" => %{"arbitrary" => [true, 2, nil]}
    }

    assert {:ok, %Compiled{} = compiled} = Validator.compile(schema)
    assert compiled.root.raw === schema
    assert Validator.validate_compiled("hello", compiled) == :ok
    assert {:error, _} = Validator.validate_compiled("a", compiled)
    assert Validator.validate_compiled("goodbye", compiled) == :ok
  end

  test "local anchors and bundled embedded resource identifiers resolve offline" do
    schema = %{
      "$id" => "https://schemas.example.test/root",
      "$defs" => %{
        "name" => %{"$anchor" => "name", "type" => "string"},
        "count" => %{"$id" => "count", "type" => "integer"}
      },
      "type" => "object",
      "properties" => %{
        "name" => %{"$ref" => "#name"},
        "count" => %{"$ref" => "count"}
      }
    }

    assert Validator.validate(%{"name" => "hello", "count" => 2}, schema) == :ok
    assert {:error, _} = Validator.validate(%{"name" => 2}, schema)
    assert {:error, _} = Validator.validate(%{"count" => "2"}, schema)
  end

  test "dynamic references use the active recursive schema" do
    schema = %{
      "$id" => "https://schemas.example.test/tree",
      "$dynamicAnchor" => "node",
      "type" => "object",
      "required" => ["value"],
      "properties" => %{
        "value" => %{"type" => "integer"},
        "children" => %{"type" => "array", "items" => %{"$dynamicRef" => "#node"}}
      },
      "unevaluatedProperties" => false
    }

    assert Validator.validate(%{"value" => 1, "children" => [%{"value" => 2}]}, schema) == :ok

    assert {:error, _} =
             Validator.validate(%{"value" => 1, "children" => [%{"value" => "two"}]}, schema)

    assert {:error, _} =
             Validator.validate(
               %{"value" => 1, "children" => [%{"value" => 2, "extra" => true}]},
               schema
             )
  end

  test "tracks evaluated properties across composition" do
    schema = %{
      "type" => "object",
      "allOf" => [%{"properties" => %{"name" => %{"type" => "string"}}}],
      "dependentSchemas" => %{
        "name" => %{"properties" => %{"age" => %{"type" => "integer"}}, "required" => ["age"]}
      },
      "unevaluatedProperties" => false
    }

    assert Validator.validate(%{"name" => "Ada", "age" => 37}, schema) == :ok
    assert {:error, _} = Validator.validate(%{"name" => "Ada"}, schema)

    assert {:error, _} =
             Validator.validate(%{"name" => "Ada", "age" => 37, "extra" => true}, schema)
  end

  test "supports prefixItems, contains bounds, and unevaluatedItems" do
    schema = %{
      "type" => "array",
      "prefixItems" => [%{"type" => "string"}],
      "contains" => %{"type" => "integer"},
      "minContains" => 1,
      "maxContains" => 2,
      "unevaluatedItems" => false
    }

    assert Validator.validate(["a", 1, 2], schema) == :ok
    assert {:error, _} = Validator.validate(["a"], schema)
    assert {:error, _} = Validator.validate(["a", 1, 2, 3], schema)
    assert {:error, _} = Validator.validate(["a", 1, false], schema)
  end

  test "supports nested and standalone boolean schemas without broadening tool registration" do
    assert {:ok, yes} = Validator.compile(true)
    assert {:ok, no} = Validator.compile(false)
    assert Validator.validate_compiled(nil, yes) == :ok
    assert {:error, _} = Validator.validate_compiled(nil, no)

    assert Validator.validate(%{"allowed" => [nil]}, %{
             "properties" => %{"allowed" => true, "forbidden" => false}
           }) == :ok

    assert {:error, _} =
             Validator.validate(%{"forbidden" => true}, %{"properties" => %{"forbidden" => false}})
  end

  test "supports explicit Draft 7 without changing the default draft" do
    schema = %{
      "$schema" => @draft7,
      "type" => "array",
      "items" => [%{"type" => "string"}, %{"type" => "integer"}],
      "additionalItems" => false
    }

    assert Validator.validate(["hello", 2], schema) == :ok
    assert {:error, _} = Validator.validate(["hello", "2"], schema)
    assert {:error, _} = Validator.validate(["hello", 2, true], schema)
    assert {:error, %BuildError{}} = Validator.compile(Map.delete(schema, "$schema"))
  end

  test "malformed schemas fail admission even when JSV's builder tolerates a keyword" do
    schemas = [
      %{"type" => "nonsense"},
      %{"minimum" => "five"},
      %{"minLength" => -1},
      %{"multipleOf" => -1},
      %{"enum" => "not-an-array"},
      %{"required" => ["a", "a"]},
      %{"uniqueItems" => "yes"},
      %{"$defs" => %{"unused" => %{"minItems" => -1}}},
      %{"properties" => %{"name" => 17}},
      %{"pattern" => "["}
    ]

    for schema <- schemas do
      assert {:error, %BuildError{}} = Validator.compile(schema), inspect(schema)
      assert_raise BuildError, fn -> Validator.validate(%{}, schema) end
    end
  end

  test "empty enum is a valid 2020-12 schema that rejects every instance" do
    assert {:ok, compiled} = Validator.compile(%{"enum" => []})
    assert {:error, _} = Validator.validate_compiled(nil, compiled)
  end

  test "rejects unknown, malformed, and mixed dialect declarations" do
    for schema <- [
          %{"$schema" => "https://schemas.example.test/custom"},
          %{"$schema" => "https://json-schema.org/draft/2019-09/schema"},
          %{"$schema" => nil},
          %{"properties" => %{"child" => %{"$schema" => @draft7}}}
        ] do
      assert {:error, %BuildError{}} = Validator.compile(schema)
    end
  end

  test "unknown required vocabularies fail closed and optional unknown vocabularies remain annotations" do
    assert {:error, %BuildError{reason: {:unsupported_vocabulary, _, _}}} =
             Validator.compile(%{
               "$vocabulary" => %{"https://schemas.example.test/custom-vocab" => true}
             })

    assert {:error, %BuildError{}} = Validator.compile(%{"$vocabulary" => %{"unknown" => "yes"}})
    assert {:error, %BuildError{}} = Validator.compile(%{"$vocabulary" => []})

    assert Validator.validate("fine", %{
             "type" => "string",
             "$vocabulary" => %{"https://schemas.example.test/custom-vocab" => false}
           }) == :ok
  end

  test "unresolved refs fail without HTTP, file access, or module resolution" do
    Code.ensure_loaded!(SnodoTest.JSV.SchemaProbe)

    for reference <- [
          "https://schemas.example.test/unavailable",
          "http://127.0.0.1:1/unavailable",
          "file:///schema-does-not-exist.json",
          "missing.json",
          "#/$defs/missing",
          "jsv:module:Elixir.SnodoTest.JSV.SchemaProbe"
        ] do
      assert {:error, %BuildError{}} = Validator.compile(%{"$ref" => reference})
    end

    refute Process.get(:jsv_schema_probe_called)
  end

  test "casting declarations fail before build-time hooks are invoked" do
    Code.ensure_loaded!(SnodoTest.JSV.CastProbe)

    for keyword <- ["x-jsv-cast", "jsv-cast"] do
      assert {:error, %BuildError{reason: {:unsupported_cast, _}}} =
               Validator.compile(%{
                 "properties" => %{
                   "name" => %{
                     "type" => "string",
                     keyword => ["Elixir.SnodoTest.JSV.CastProbe", "cast"]
                   }
                 }
               })
    end

    refute Process.get(:jsv_cast_probe_called)
  end

  test "formats are annotations by default and assertion is an explicit compiled-root policy" do
    schema = %{"type" => "string", "format" => "date"}
    assert Validator.validate("not-a-date", schema) == :ok
    assert {:ok, annotation} = Validator.compile(schema, formats: :annotation)
    assert Validator.validate_compiled("not-a-date", annotation) == :ok
    assert {:ok, assertion} = Validator.compile(schema, formats: :assertion)
    assert {:error, _} = Validator.validate_compiled("not-a-date", assertion)
    assert Validator.validate_compiled("2026-09-14", assertion) == :ok

    custom = %{"type" => "string", "format" => "application-specific"}
    assert Validator.validate("any", custom) == :ok
    assert {:error, %BuildError{}} = Validator.compile(custom, formats: :assertion)
  end

  test "defaults, read/write annotations, and exact numeric values are not transformed" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "count" => %{"type" => "integer"},
        "name" => %{"type" => "string", "default" => "default", "readOnly" => true}
      }
    }

    instance = %{"count" => 1.0}
    assert Validator.validate(instance, schema) == :ok
    assert instance === %{"count" => 1.0}
    refute Map.has_key?(instance, "name")
  end

  test "accepts property names that resemble schema keywords" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "$schema" => %{"type" => "string"},
        "x-jsv-cast" => %{"type" => "integer"}
      }
    }

    assert Validator.validate(%{"$schema" => "a value", "x-jsv-cast" => 1}, schema) == :ok
  end

  test "rejects non-JSON input terms without normalizing atoms or structs" do
    assert {:ok, compiled} = Validator.compile(%{})

    for value <- [%{name: "hello"}, :hello, Date.utc_today(), {1, 2}] do
      assert Validator.validate_compiled(value, compiled) == {:error, :not_a_json_value}
    end

    for schema <- [%{type: :object}, [], nil, :string, %{"default" => :atom}] do
      assert {:error, %BuildError{}} = Validator.compile(schema)
    end
  end

  test "unknown configuration cannot enable a resolver or casts" do
    for options <- [[resolver: JSV.Resolver.Httpc], [atoms: true], [formats: true], [cast: true]] do
      assert {:error, %BuildError{reason: :invalid_options}} = Validator.compile(%{}, options)
    end
  end

  test "application resource identifiers cannot replace trusted bundled meta-schemas" do
    schema = %{
      "$id" => @draft202012,
      "$schema" => @draft202012,
      "$vocabulary" => %{"https://json-schema.org/draft/2020-12/vocab/core" => true},
      "type" => "string"
    }

    assert {:error, %BuildError{}} = Validator.compile(schema)

    assert {:error, %BuildError{}} =
             Validator.compile(%{
               "$id" => "https://JSON-SCHEMA.ORG/draft/2020-12/",
               "$defs" => %{"replacement" => Map.put(schema, "$id", "schema")}
             })
  end

  test "references cannot turn annotation containers into executable casting schemas" do
    Code.ensure_loaded!(SnodoTest.JSV.CastProbe)
    cast = %{"properties" => %{"x-jsv-cast" => [["Elixir.SnodoTest.JSV.CastProbe", "cast"]]}}

    for {annotation, value, target} <- [
          {"x-hidden", cast, "#/x-hidden/properties"},
          {"default", cast, "#/default/properties"},
          {"enum", [cast], "#/enum/0/properties"},
          {"examples", [cast], "#/examples/0/properties"}
        ],
        reference_keyword <- ["$ref", "$dynamicRef"] do
      Process.delete(:jsv_cast_probe_called)

      assert {:error, %BuildError{}} =
               Validator.compile(%{reference_keyword => target, annotation => value})

      refute Process.get(:jsv_cast_probe_called)
    end
  end

  test "only meta-schema-validated schema positions may be reference targets" do
    invalid = %{"required" => ["a", "a"]}

    for {annotation, value, target} <- [
          {"x-hidden", invalid, "#/x-hidden"},
          {"default", invalid, "#/default"},
          {"enum", [invalid], "#/enum/0"},
          {"examples", [invalid], "#/examples/0"}
        ] do
      assert {:error, %BuildError{reason: {:unsupported_reference_target, _, _}}} =
               Validator.compile(%{"$ref" => target, annotation => value})
    end

    # A map of schemas is not itself a validated schema position, even when a
    # property happens to have a name that is meaningful as a schema keyword.
    assert {:error, %BuildError{}} =
             Validator.compile(%{
               "$ref" => "#/properties",
               "properties" => %{"type" => %{"type" => "string"}}
             })
  end

  test "anchor, identifier and encoded-pointer indirection cannot admit hidden schema controls" do
    Code.ensure_loaded!(SnodoTest.JSV.CastProbe)
    injection = %{"properties" => %{"x-jsv-cast" => [["Elixir.SnodoTest.JSV.CastProbe", "cast"]]}}

    for schema <- [
          %{"$ref" => "#hidden", "default" => Map.put(injection, "$anchor", "hidden")},
          %{
            "$dynamicRef" => "#hidden",
            "enum" => [Map.put(injection, "$dynamicAnchor", "hidden")]
          },
          %{
            "$ref" => "https://schemas.example.test/hidden",
            "x-hidden" => Map.put(injection, "$id", "https://schemas.example.test/hidden")
          },
          %{"$ref" => "#%2Fx-hidden%2Fproperties", "x-hidden" => injection},
          %{
            "$ref" => "#/x-hidden/properties",
            "x-hidden" => %{"properties" => %{"$id" => @draft202012, "$schema" => @draft202012}}
          },
          %{"$schema" => @draft7, "$ref" => "#/$defs/hidden", "$defs" => %{"hidden" => injection}}
        ] do
      Process.delete(:jsv_cast_probe_called)
      assert {:error, %BuildError{}} = Validator.compile(schema)
      refute Process.get(:jsv_cast_probe_called)
    end
  end

  test "resource-relative pointers and escaped property names remain supported" do
    schema = %{
      "$id" => "https://schemas.example.test/root",
      "$defs" => %{
        "nested" => %{"$id" => "nested", "$defs" => %{"a/b~c" => %{"type" => "integer"}}}
      },
      "$ref" => "nested#/$defs/a~1b~0c"
    }

    assert Validator.validate(3, schema) == :ok
    assert {:error, _reason} = Validator.validate("three", schema)
  end
end
