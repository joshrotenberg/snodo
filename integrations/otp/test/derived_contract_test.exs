defmodule Snodo.OTP.DerivedContractTest do
  use ExUnit.Case, async: false

  alias Snodo.OTP.Proxy
  alias Snodo.Transport.StreamableHTTP.Server, as: HTTPServer
  alias SnodoTest.OTP.Counter
  alias SnodoTest.OTP.CounterContract
  alias SnodoTest.OTP.DerivedCounterContract, as: Derived
  alias SnodoTest.OTP.DerivedCounterServer

  describe "generated callbacks" do
    test "ops/0 lists the declarations in order without :message or :reply" do
      assert Derived.ops() == CounterContract.ops()
    end

    test "each side agrees with the hand-written contract" do
      for message <- [:get, {:add, 2}, {:slow, 10}] do
        assert Derived.encode_call(message) == CounterContract.encode_call(message)
        {name, args} = Derived.encode_call(message)
        assert Derived.build_message(name, args) == message
      end

      assert Derived.encode_cast({:add, 3}) == {"counter_cast_add", %{"by" => 3}}
      assert Derived.build_message("counter_cast_add", %{"by" => 3}) == {:add, 3}
      assert Derived.encode_reply("counter_add", 7) == %{"value" => 7}
      assert Derived.decode_reply("counter_add", %{"value" => 7}) == 7
    end

    test "a message no operation declares is :nomatch" do
      assert Derived.encode_call(:reset) == :nomatch
      assert Derived.encode_call({:add, 1, 2}) == :nomatch
      assert Derived.encode_cast(:get) == :nomatch
    end

    test "a reply without the declared key does not decode" do
      assert_raise ArgumentError, fn -> Derived.decode_reply("counter_add", %{"total" => 1}) end
    end

    test "nested tuples, lists, maps and a repeated argument" do
      [{name, _}] =
        compile("""
        use Snodo.OTP.Contract
        call("put",
          message: {:put, %{key: {:arg, "k"}}, [{:arg, "v"}, :tag], {:arg, "k"}},
          reply: "ok",
          input_schema: %{"type" => "object"}
        )
        """)

      message = {:put, %{key: "a"}, [1, :tag], "a"}
      assert {"put", %{"k" => "a", "v" => 1}} = name.encode_call(message)
      assert name.build_message("put", %{"k" => "a", "v" => 1}) == message
      # The repeated argument must hold the same value in both places.
      assert name.encode_call({:put, %{key: "a"}, [1, :tag], "b"}) == :nomatch
    end
  end

  describe "compile-time checks" do
    test "a duplicate operation name" do
      assert_compile_error(~r/duplicate operation "a"/, """
      use Snodo.OTP.Contract
      cast("a", message: :x, input_schema: %{})
      cast("a", message: :y, input_schema: %{})
      """)
    end

    test "a missing :message" do
      assert_compile_error(~r/needs :message/, """
      use Snodo.OTP.Contract
      cast("a", input_schema: %{})
      """)
    end

    test "a call without :reply and a cast with one" do
      assert_compile_error(~r/call "a" needs :reply/, """
      use Snodo.OTP.Contract
      call("a", message: :x, input_schema: %{})
      """)

      assert_compile_error(~r/cast "a" has no reply/, """
      use Snodo.OTP.Contract
      cast("a", message: :x, reply: "v", input_schema: %{})
      """)
    end

    test "an argument the input schema does not list" do
      assert_compile_error(~r/not in its input schema: \["n"\]/, """
      use Snodo.OTP.Contract
      cast("a",
        message: {:x, {:arg, "n"}},
        input_schema: %{"type" => "object", "properties" => %{"m" => %{}}}
      )
      """)
    end
  end

  describe "over MCP" do
    setup do
      start_supervised!(Counter)

      server =
        start_supervised!({HTTPServer, runtime: DerivedCounterServer.runtime(), port: 0})

      url = HTTPServer.url(server)
      %{url: url, proxy: start_supervised!({Proxy, url: url, contract: Derived})}
    end

    test "the server and the proxy both run from the declarations", %{proxy: proxy, url: url} do
      {:ok, client} = Snodo.Client.connect({:http, url}, protocol: "2026-07-28")
      {:ok, tools} = Snodo.Client.list_tools(client)

      assert tools |> Enum.map(& &1["name"]) |> Enum.sort() ==
               ["counter_add", "counter_cast_add", "counter_get", "counter_slow"]

      assert GenServer.call(proxy, :get) == 0
      assert GenServer.call(proxy, {:add, 2}) == 2
      :ok = GenServer.cast(proxy, {:add, 3})
      assert GenServer.call(proxy, :get) == 5
    end
  end

  defp compile(body) do
    id = System.unique_integer([:positive])
    Code.compile_string("defmodule SnodoTest.OTP.Derived#{id} do\n#{body}\nend")
  end

  defp assert_compile_error(pattern, body) do
    error = assert_raise CompileError, fn -> compile(body) end
    assert Exception.message(error) =~ pattern
  end
end
