defmodule MCP.RouterAcceptanceTest do
  use ExUnit.Case, async: true

  alias MCP.Context
  alias MCP.Error
  alias MCP.Protocol.V2026_07_28
  alias MCP.Result
  alias MCP.Router
  alias MCP.Tool.Definition
  alias MCP.Transport.Context, as: TransportContext
  alias MCPEx.TestTools.Barrier
  alias MCPEx.TestTools.ComplexSchema
  alias MCPEx.TestTools.Echo
  alias MCPEx.TestTools.EchoCollision
  alias MCPEx.TestTools.Failing
  alias MCPEx.TestTools.InvalidInputSchema

  defp context(metadata \\ %{}) do
    %Context{
      protocol_version: "2026-07-28",
      protocol: V2026_07_28,
      transport: %TransportContext{transport: :direct},
      metadata: metadata
    }
  end

  test "registration is immutable and schemas survive unchanged" do
    empty = Router.new()
    router = empty |> Router.register_tool(Echo) |> Router.register_tool(ComplexSchema)

    assert empty.tools == %{}
    assert router.tools == %{"complex_schema" => ComplexSchema, "echo" => Echo}

    [complex_definition, echo_definition] = Router.list_tools(router)
    assert complex_definition.name == "complex_schema"
    assert complex_definition.output_schema == ComplexSchema.output_schema()

    definition = echo_definition
    assert %Definition{} = definition
    assert definition.input_schema == Echo.input_schema()
    assert definition.output_schema == nil
    assert definition.input_schema["x-vendor-missing"] == nil
    assert definition.input_schema["$defs"]["text"]["x-vendor-nested"] == [true, 7, nil]
  end

  test "duplicate names never silently overwrite" do
    router = Router.new() |> Router.register_tool(Echo)

    assert_raise ArgumentError, ~r/already registered/, fn ->
      Router.register_tool(router, EchoCollision)
    end

    assert router.tools["echo"] == Echo
  end

  test "registration rejects non-object tool input schemas" do
    assert_raise ArgumentError, ~r/object-root JSON Schema/, fn ->
      Router.register_tool(Router.new(), InvalidInputSchema)
    end
  end

  test "direct dispatch executes in the caller and normalizes results" do
    router = Router.new() |> Router.register_tool(Echo) |> Router.register_tool(Failing)
    caller = self()

    assert self() == caller

    assert {:ok, %Result{kind: :text, value: "hello"}} =
             Router.dispatch(
               router,
               {:tools_call, "echo"},
               %{"arguments" => %{"text" => "hello"}},
               context()
             )

    assert {:ok, %Result{kind: :error, value: "Actionable domain failure"}} =
             Router.dispatch(router, {:tools_call, "failing"}, %{}, context())
  end

  test "unknown tools remain protocol-neutral errors" do
    assert {:error, %Error{code: -32_602, kind: :protocol}} =
             Router.dispatch(Router.new(), {:tools_call, "missing"}, %{}, context())
  end

  @tag timeout: 15_000
  test "100 independent calls can all enter a barrier before any is released" do
    router = Router.new() |> Router.register_tool(Barrier)
    owner = self()

    tasks =
      for index <- 1..100 do
        Task.async(fn ->
          Router.dispatch(
            router,
            {:tools_call, "barrier"},
            %{"arguments" => %{"owner" => owner, "index" => index}},
            context()
          )
        end)
      end

    entrants =
      for _ <- 1..100 do
        assert_receive {:entered, index, pid}, 5_000
        {index, pid}
      end

    assert entrants |> Enum.map(&elem(&1, 0)) |> Enum.sort() == Enum.to_list(1..100)

    Enum.each(entrants, fn {index, pid} -> send(pid, {:release, index}) end)

    assert Enum.all?(tasks, fn task ->
             match?({:ok, %Result{kind: :structured}}, Task.await(task, 5_000))
           end)
  end
end
