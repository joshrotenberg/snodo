defmodule Snodo.InputBoundsTest do
  use ExUnit.Case, async: true

  alias Snodo.Envelope
  alias Snodo.JSONValue
  alias Snodo.Transport.Stdio
  alias SnodoTest.TestFixtures

  test "decoding refuses integer literals over 64 digits and trailing data" do
    digits = String.duplicate("9", 64)
    assert {:ok, %{"n" => n}} = JSONValue.decode(~s({"n":#{digits}}))
    assert n == String.to_integer(digits)
    assert {:ok, [-1, 2.5]} = JSONValue.decode("[-1, 2.5]\n")

    assert {:error, :integer_too_long} = JSONValue.decode(~s({"n":#{digits}9}))

    # The sign is not a digit.
    assert {:ok, %{"n" => negative}} = JSONValue.decode(~s({"n":-#{digits}}))
    assert negative == -String.to_integer(digits)
    assert {:error, :integer_too_long} = JSONValue.decode(~s({"n":-#{digits}9}))
    assert {:error, :trailing_data} = JSONValue.decode(~s({"a":1} x))
    assert {:error, _reason} = JSONValue.decode("{not-json")

    # The standard decoder raises SystemLimitError at about 1.25 million digits.
    {elapsed, result} =
      :timer.tc(fn -> JSONValue.decode(~s({"n":#{String.duplicate("9", 2_000_000)}})) end)

    assert result == {:error, :integer_too_long}
    assert elapsed < 1_000_000
  end

  test "decoding refuses duplicate object keys at every depth" do
    assert {:error, :duplicate_key} = JSONValue.decode(~s({"a":1,"a":2}))
    assert {:error, :duplicate_key} = JSONValue.decode(~s({"a":{"b":1,"b":2}}))
    assert {:error, :duplicate_key} = JSONValue.decode(~S({"a":1,"\u0061":2}))
    assert {:ok, [%{"a" => 1}, %{"a" => 2}]} = JSONValue.decode(~s([{"a":1},{"a":2}]))
  end

  test "stdio answers a duplicate-key request with a parse error and keeps serving" do
    duplicate = ~s({"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"a":1,"a":2}})
    valid = TestFixtures.request(2, "tools/list")
    {:ok, io} = StringIO.open(duplicate <> "\n" <> JSON.encode!(valid) <> "\n")

    assert :ok = Stdio.serve(TestFixtures.runtime(), input: io, output: io)
    {_input, output} = StringIO.contents(io)

    assert [%{"id" => nil, "error" => %{"code" => -32_700}}, %{"id" => 2, "result" => _}] =
             output |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
  end

  test "ids and progress tokens are bounded" do
    assert Envelope.bounded_id?(String.duplicate("a", 256))
    refute Envelope.bounded_id?(String.duplicate("a", 257))
    assert Envelope.bounded_id?(9_223_372_036_854_775_807)
    refute Envelope.bounded_id?(9_223_372_036_854_775_808)
    assert Envelope.bounded_id?(-9_223_372_036_854_775_808)
    refute Envelope.bounded_id?(1.5)
  end

  test "stdio answers an oversized integer or id without echoing it and keeps serving" do
    runtime = TestFixtures.runtime()

    # Under the 2 MB line limit, over the ~1.25 million digits that raise.

    huge =
      ~s({"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"n":) <>
        String.duplicate("9", 1_500_000) <> "}}"

    long_id = TestFixtures.request(String.duplicate("a", 300), "tools/list")
    valid = TestFixtures.request(3, "tools/list")

    input = Enum.join([huge, JSON.encode!(long_id), JSON.encode!(valid)], "\n") <> "\n"
    {:ok, io} = StringIO.open(input)
    assert :ok = Stdio.serve(runtime, input: io, output: io)
    {_input, output} = StringIO.contents(io)
    responses = output |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

    assert Enum.any?(responses, &match?(%{"id" => nil, "error" => %{"code" => -32_700}}, &1))
    assert Enum.any?(responses, &match?(%{"id" => nil, "error" => %{"code" => -32_600}}, &1))
    assert Enum.any?(responses, &match?(%{"id" => 3, "result" => _}, &1))
    refute output =~ String.duplicate("a", 300)
  end
end
