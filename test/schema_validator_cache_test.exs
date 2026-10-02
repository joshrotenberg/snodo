defmodule Snodo.SchemaValidatorCacheTest.PatternTool do
  @moduledoc false
  use Snodo.Tool, name: "cache_pattern"

  input_schema(%{
    "type" => "object",
    "properties" => %{"text" => %{"type" => "string", "pattern" => "^runtime-cache-ok$"}}
  })

  @impl true
  def call(%{"text" => text}, _context), do: {:ok, Snodo.Result.text(text)}
end

defmodule Snodo.SchemaValidatorCacheTest.TermErrorValidator do
  @moduledoc false
  @behaviour Snodo.Schema.Validator

  @impl true
  def validate(_instance, _schema), do: :ok

  @impl true
  def compile(_schema), do: {:error, :invalid_schema}

  @impl true
  def validate_compiled(_instance, _compiled), do: :ok
end

defmodule Snodo.SchemaValidatorCacheTest do
  use ExUnit.Case, async: false

  alias Snodo.Schema.Validator.Basic
  alias Snodo.Schema.Validator.Cache
  alias Snodo.SchemaValidatorCacheTest.PatternTool
  alias Snodo.SchemaValidatorCacheTest.TermErrorValidator

  test "concurrent first uses compile a key once" do
    {:ok, count} = Agent.start_link(fn -> 0 end)
    key = {:test_schema, make_ref()}

    results =
      1..32
      |> Task.async_stream(
        fn _index ->
          Cache.fetch(key, fn ->
            Agent.update(count, &(&1 + 1))
            :compiled
          end)
        end,
        max_concurrency: 32,
        timeout: 5_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, &(&1 == {:ok, :compiled}))
    assert Agent.get(count, & &1) == 1
  end

  test "a slow schema does not block compilation of another key" do
    parent = self()

    first =
      Task.async(fn ->
        Cache.fetch({:slow_schema, make_ref()}, fn ->
          send(parent, {:compiling, self()})

          receive do
            :release -> :first
          end
        end)
      end)

    assert_receive {:compiling, worker}, 1_000

    second = Task.async(fn -> Cache.fetch({:other_schema, make_ref()}, fn -> :second end) end)
    assert Task.await(second, 1_000) == :second

    send(worker, :release)
    assert Task.await(first, 1_000) == :first
  end

  test "unexpected compilation failure reaches callers and does not poison the cache" do
    key = {:raising_schema, make_ref()}

    assert_raise RuntimeError, "compilation failed", fn ->
      Cache.fetch(key, fn -> raise "compilation failed" end)
    end

    assert Cache.fetch(key, fn -> :recovered end) == :recovered
  end

  test "the cache evicts old entries instead of growing without bound" do
    {:ok, count} = Agent.start_link(fn -> 0 end)
    first = {:test_schema, make_ref()}

    compile = fn ->
      Agent.update(count, &(&1 + 1))
      :compiled
    end

    assert Cache.fetch(first, compile) == :compiled

    for index <- 1..256 do
      assert Cache.fetch({:test_schema, make_ref(), index}, fn -> :compiled end) == :compiled
    end

    assert :ets.info(Cache, :size) == 256
    assert Cache.fetch(first, compile) == :compiled
    assert Agent.get(count, & &1) == 2
  end

  test "Basic reuses regex compilation and preserves invalid-pattern errors" do
    id = System.unique_integer([:positive])
    pattern = "^cache-probe-#{id}$"
    schema = %{"type" => "string", "pattern" => pattern}

    assert :ok = Basic.validate("cache-probe-#{id}", schema)

    assert {:ok, %Regex{}} =
             Cache.fetch({Basic, :pattern, pattern}, fn -> flunk("pattern was not cached") end)

    invalid = %{"type" => "string", "pattern" => "["}
    assert {:error, %{keyword: "pattern"}} = Basic.validate("anything", invalid)
  end

  test "registered schemas keep compiled patterns outside the bounded fallback cache" do
    router = Snodo.Router.new() |> Snodo.Router.register_tool(PatternTool)

    runtime =
      Snodo.Server.Runtime.new(
        router: router,
        protocols: [Snodo.Protocol.V2026_07_28],
        server_info: %{"name" => "cache-test", "version" => "1"},
        schema_validator: Basic
      )

    assert {:ok, {_schema, %{"^runtime-cache-ok$" => {:ok, %Regex{}}}}} =
             runtime.compiled_schemas[PatternTool.input_schema()]

    for index <- 1..257 do
      Cache.fetch({:fallback, index}, fn -> :compiled end)
    end

    {:ok, client} = Snodo.Client.direct(runtime)

    assert {:ok, %{"content" => [%{"text" => "runtime-cache-ok"}]}} =
             Snodo.Client.call_tool(client, "cache_pattern", %{"text" => "runtime-cache-ok"})

    assert :ets.lookup(Cache, {Basic, :pattern, "^runtime-cache-ok$"}) == []
  end

  test "a compilation error term remains the internal error cause" do
    router = Snodo.Router.new() |> Snodo.Router.register_tool(PatternTool)

    runtime =
      Snodo.Server.Runtime.new(
        router: router,
        protocols: [Snodo.Protocol.V2026_07_28],
        server_info: %{"name" => "cache-test", "version" => "1"},
        schema_validator: TermErrorValidator
      )

    context = %Snodo.Context{
      protocol_version: "2026-07-28",
      protocol: Snodo.Protocol.V2026_07_28,
      transport: %Snodo.Transport.Context{transport: :direct}
    }

    assert {:error, %Snodo.Error{message: "Schema validator failed", cause: cause}} =
             Snodo.Router.check(
               router,
               {:tools_call, "cache_pattern"},
               %{"arguments" => %{"text" => "runtime-cache-ok"}},
               context,
               schema_validator: TermErrorValidator,
               compiled_schemas: runtime.compiled_schemas
             )

    assert cause == {:compile_error, :invalid_schema}
  end
end
