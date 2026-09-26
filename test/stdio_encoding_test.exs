defmodule Snodo.Transport.StdioEncodingTest do
  use ExUnit.Case, async: true

  alias Snodo.Transport.Stdio
  alias Snodo.Transport.Stdio.Framing
  alias SnodoTest.TestFixtures
  alias SnodoTest.TestInput

  @text "héllo 日本 😀 line\u2028separator\u2029end"

  test "encoded lines are ASCII and decode to the original text" do
    line = %{"text" => @text} |> Framing.encode_message() |> IO.iodata_to_binary()

    assert line =~ ~r/\A[\x00-\x7F]+\z/
    assert String.ends_with?(line, "\n")
    assert line =~ ~S(\ud83d\ude00)
    assert line =~ ~S(\u2028)
    assert {:ok, %{"text" => @text}} = Framing.decode_line(line)
  end

  test "a leading byte order mark is ignored" do
    line = <<0xEF, 0xBB, 0xBF>> <> ~s({"jsonrpc":"2.0","id":1,"method":"ping"}\n)
    assert {:ok, %{"id" => 1, "method" => "ping"}} = Framing.decode_line(line)
  end

  test "a line over :max_line_bytes is refused without decoding and the next is served" do
    {:ok, input} = TestInput.start_link()
    {:ok, output} = StringIO.open("")

    server =
      Task.async(fn ->
        Stdio.serve(TestFixtures.runtime(), input: input, output: output, max_line_bytes: 400)
      end)

    long =
      TestFixtures.request("long", "tools/call", %{
        "name" => "echo",
        "arguments" => %{"text" => String.duplicate("x", 500)}
      })

    TestInput.push(input, JSON.encode!(long) <> "\n")
    TestInput.push(input, JSON.encode!(echo_request("after")) <> "\n")
    TestInput.eof(input)
    assert :ok = Task.await(server, 5_000)

    {_input, raw_output} = StringIO.contents(output)
    [refused, served] = raw_output |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

    assert %{"id" => nil, "error" => %{"code" => -32_600, "message" => message}} = refused
    assert message =~ "400-byte line limit"
    assert %{"id" => "after", "result" => %{"isError" => false}} = served
  end

  test ":max_line_bytes must be a positive integer" do
    Process.flag(:trap_exit, true)
    {:ok, io} = StringIO.open("")

    assert {:error, {%ArgumentError{message: message}, _stacktrace}} =
             Stdio.start_link(
               runtime: TestFixtures.runtime(),
               input: io,
               output: io,
               max_line_bytes: 0
             )

    assert message =~ ":max_line_bytes"
  end

  test "ASCII-only messages are encoded unchanged" do
    message = %{"jsonrpc" => "2.0", "id" => 1, "result" => %{"text" => "plain"}}

    assert IO.iodata_to_binary(Framing.encode_message(message)) ==
             JSON.encode!(message) <> "\n"
  end

  test "non-ASCII tool output survives a Unicode-mode output device" do
    {:ok, input} = TestInput.start_link()
    {:ok, output} = StringIO.open("", encoding: :unicode)

    server =
      Task.async(fn -> Stdio.serve(TestFixtures.runtime(), input: input, output: output) end)

    TestInput.push(input, JSON.encode!(echo_request("unicode")) <> "\n")
    TestInput.eof(input)
    assert :ok = Task.await(server, 5_000)

    {_input, raw_output} = StringIO.contents(output)

    assert %{"id" => "unicode", "result" => %{"content" => [%{"text" => @text}]}} =
             raw_output |> String.trim() |> JSON.decode!()
  end

  test "UTF-8 input from a Latin-1 device is read as bytes" do
    path = Path.join(System.tmp_dir!(), "snodo_latin1_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(path) end)
    File.write!(path, JSON.encode!(echo_request("latin1-input")) <> "\n")

    {:ok, input} = File.open(path, [:read])
    assert Keyword.get(:io.getopts(input), :encoding) == :latin1
    {:ok, output} = StringIO.open("", encoding: :unicode)

    assert :ok = Stdio.serve(TestFixtures.runtime(), input: input, output: output)
    {_input, raw_output} = StringIO.contents(output)

    assert %{"result" => %{"content" => [%{"text" => @text}]}} =
             raw_output |> String.trim() |> JSON.decode!()
  end

  @tag timeout: 30_000
  test "raw UTF-8 piped into a subprocess round-trips" do
    fixture = Path.expand("fixtures/client_stdio_server.exs", __DIR__)
    ebin = Path.expand(Mix.Project.compile_path())

    port =
      Port.open({:spawn_executable, System.find_executable("elixir")}, [
        :binary,
        :exit_status,
        {:line, 65_536},
        {:args, ["-pa", ebin, fixture]},
        {:env, [{~c"LANG", ~c"C"}, {~c"LC_ALL", ~c"C"}]}
      ])

    on_exit(fn -> if Port.info(port), do: Port.close(port) end)

    # JSON.encode! leaves non-ASCII characters as raw UTF-8 bytes.
    request = JSON.encode!(echo_request("piped"))
    assert request =~ "日本"
    true = Port.command(port, request <> "\n")

    assert_receive {^port, {:data, {:eol, line}}}, 20_000

    assert %{"id" => "piped", "result" => %{"content" => [%{"text" => @text}]}} =
             JSON.decode!(line)
  end

  defp echo_request(id) do
    TestFixtures.request(id, "tools/call", %{"name" => "echo", "arguments" => %{"text" => @text}})
  end
end
