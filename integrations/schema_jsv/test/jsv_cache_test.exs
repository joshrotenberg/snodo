defmodule Snodo.Schema.Validator.JSVCacheTest do
  use ExUnit.Case, async: false

  alias Snodo.Schema.Validator.Cache
  alias Snodo.Schema.Validator.JSV, as: Validator
  alias Snodo.Schema.Validator.JSV.BuildError
  alias Snodo.Schema.Validator.JSV.Compiled
  alias SnodoTest.JSV.{BadSchema, Echo, Server}

  test "validation reuses a compiled schema without changing results" do
    schema = %{"type" => "string", "$comment" => inspect(make_ref())}

    assert Validator.validate("accepted", schema) == :ok
    assert {:error, _reason} = Validator.validate(42, schema)

    assert {:ok, %Compiled{}} =
             Cache.fetch({Validator, schema}, fn -> flunk("schema was not cached") end)
  end

  test "a cached build error still raises on each validation" do
    schema = %{"type" => "not-a-type", "$comment" => inspect(make_ref())}

    assert_raise BuildError, fn -> Validator.validate("value", schema) end
    assert_raise BuildError, fn -> Validator.validate("value", schema) end

    assert {:error, %BuildError{}} =
             Cache.fetch({Validator, schema}, fn -> flunk("build error was not cached") end)
  end

  test "server runtime retains compiled schemas and defers build errors" do
    runtime = Server.runtime()

    assert {:ok, %Compiled{}} = runtime.compiled_schemas[Echo.input_schema()]
    assert {:ok, %Compiled{}} = runtime.compiled_schemas[Echo.output_schema()]
    assert {:error, %BuildError{}} = runtime.compiled_schemas[BadSchema.input_schema()]
  end
end
