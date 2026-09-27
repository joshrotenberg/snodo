defmodule Snodo.RouterAcceptanceTest do
  use ExUnit.Case, async: true

  alias Snodo.Context
  alias Snodo.Error
  alias Snodo.Protocol.V2026_07_28
  alias Snodo.Result
  alias Snodo.Router
  alias Snodo.Tool.Definition
  alias Snodo.Transport.Context, as: TransportContext
  alias SnodoTest.TestTools.Barrier
  alias SnodoTest.TestTools.ComplexSchema
  alias SnodoTest.TestTools.Echo
  alias SnodoTest.TestTools.EchoCollision
  alias SnodoTest.TestTools.Failing
  alias SnodoTest.TestTools.InvalidInputSchema

  defmodule Probe do
    use Snodo.Tool, name: "probe"

    input_schema(%{
      "type" => "object",
      "properties" => %{"text" => %{"type" => "string"}},
      "required" => ["text"]
    })

    @impl true
    def call(_arguments, context) do
      send(context.metadata.owner, :probe_ran)
      {:ok, Result.text("ran")}
    end
  end

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

  test "check/5 returns what dispatch/5 would without calling the tool" do
    router = Router.register_tool(Router.new(), Probe)
    context = context(%{owner: self()})
    valid = %{"arguments" => %{"text" => "hi"}}

    assert :ok = Router.check(router, {:tools_call, "probe"}, valid, context)

    assert {:ok, %Result{kind: :error}} =
             Router.check(router, {:tools_call, "probe"}, %{"arguments" => %{}}, context)

    assert {:error, %Error{code: -32_602}} =
             Router.check(router, {:tools_call, "missing"}, valid, context)

    assert {:error, %Error{code: -32_004}} =
             Router.check(router, {:tools_call, "probe"}, valid, context,
               authorization: SnodoTest.TestAuthorization.DenyAll
             )

    assert {:error, %Error{code: -32_601}} =
             Router.check(router, {:prompt_get, "probe"}, %{}, context)

    refute_received :probe_ran

    assert {:ok, %Result{kind: :text}} =
             Router.dispatch(router, {:tools_call, "probe"}, valid, context)

    assert_received :probe_ran
  end

  test "Extension.check_dispatch/3 fails closed outside server middleware" do
    assert {:error, %Error{code: -32_603}} =
             Snodo.Extension.check_dispatch({:tools_call, "probe"}, %{}, context())

    checked = %{context() | dispatch_check: fn _operation, _params, _context -> :ok end}
    assert :ok = Snodo.Extension.check_dispatch({:tools_call, "probe"}, %{}, checked)
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
