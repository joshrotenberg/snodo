defmodule Snodo.Transport.StdioSubprocessAcceptanceTest do
  use ExUnit.Case, async: true

  alias SnodoTest.TestFixtures

  @logger_marker "STDIO_FIXTURE_LOGGER"
  @raw_io_marker "STDIO_FIXTURE_RAW_IO"

  @tag timeout: 15_000
  test "an OS subprocess reserves stdout for newline-delimited JSON" do
    request = %{
      "jsonrpc" => "2.0",
      "id" => "subprocess-1",
      "method" => "tools/call",
      "params" => %{
        "name" => "noisy",
        "arguments" => %{"text" => "clean response"},
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }

    stderr_path =
      Path.join(
        System.tmp_dir!(),
        "snodo_stdio_stderr_#{System.unique_integer([:positive])}.log"
      )

    on_exit(fn -> File.rm(stderr_path) end)

    fixture_path = Path.expand("../examples/stdio_subprocess_server.exs", __DIR__)
    ebin_path = Path.expand(Mix.Project.compile_path())

    shell =
      ~S"""
      printf '%s\n' "$MCP_REQUEST" | "$MCP_ELIXIR" -pa "$MCP_EBIN" "$MCP_FIXTURE" 2>"$MCP_STDERR"
      """

    {stdout, status} =
      System.cmd("/bin/sh", ["-c", shell],
        env: [
          {"MCP_REQUEST", JSON.encode!(request)},
          {"MCP_ELIXIR", System.find_executable("elixir")},
          {"MCP_EBIN", ebin_path},
          {"MCP_FIXTURE", fixture_path},
          {"MCP_STDERR", stderr_path}
        ]
      )

    stderr = File.read!(stderr_path)
    stdout_lines = String.split(stdout, "\n", trim: true)

    assert status == 0, "subprocess stderr:\n#{stderr}"
    assert [json_line] = stdout_lines
    refute stdout =~ @logger_marker
    refute stdout =~ @raw_io_marker

    assert %{
             "jsonrpc" => "2.0",
             "id" => "subprocess-1",
             "result" => %{
               "content" => [%{"type" => "text", "text" => "clean response"}],
               "isError" => false
             }
           } = JSON.decode!(json_line)

    assert String.ends_with?(stdout, "\n")
    assert stderr =~ @logger_marker
    assert stderr =~ @raw_io_marker
  end

  describe "an unterminated line over :max_line_bytes" do
    @max_line_bytes 1_000_000
    @line_megabytes 64

    # Gives the server a Unix socketpair on stdin, as Node.js clients do, and
    # copies this relay's own stdin into it.
    @socketpair_relay ~S"""
    import socket, subprocess, sys
    parent, child = socket.socketpair()
    server = subprocess.Popen(sys.argv[1:], stdin=child)
    child.close()
    while True:
        data = sys.stdin.buffer.read1(65536)
        if not data:
            break
        parent.sendall(data)
    parent.shutdown(socket.SHUT_WR)
    sys.exit(server.wait())
    """

    @tag timeout: 60_000
    test "is refused as it arrives when the VM runs with -noinput" do
      elixir = System.find_executable("elixir")
      server = start_line_limit_server(elixir, ["--erl", "-noinput"])
      assert_long_line_refused_as_it_arrives(server)
    end

    @tag timeout: 60_000
    @tag skip:
           (cond do
              String.to_integer(System.otp_release()) < 28 ->
                "OTP 27 reads a socket on stdin a line at a time"

              is_nil(System.find_executable("python3")) ->
                "python3 creates the socketpair"

              true ->
                false
            end)
    test "is refused as it arrives when stdin is a socket" do
      server =
        start_line_limit_server(System.find_executable("python3"), [
          "-c",
          @socketpair_relay,
          System.find_executable("elixir")
        ])

      assert_long_line_refused_as_it_arrives(server)
    end

    defp start_line_limit_server(executable, args) do
      fixture = Path.expand("fixtures/stdio_line_limit_server.exs", __DIR__)
      ebin = Path.expand(Mix.Project.compile_path())

      port =
        Port.open({:spawn_executable, executable}, [
          :binary,
          :exit_status,
          {:line, 65_536},
          {:args, args ++ ["-pa", ebin, fixture]},
          {:env, [{~c"SNODO_MAX_LINE_BYTES", ~c"#{@max_line_bytes}"}]}
        ])

      on_exit(fn -> if Port.info(port), do: Port.close(port) end)
      port
    end

    defp assert_long_line_refused_as_it_arrives(server) do
      chunk = String.duplicate("x", 1_000_000)
      for _megabyte <- 1..@line_megabytes, do: true = Port.command(server, chunk)

      # No newline has been sent, so a line-at-a-time reader could not answer.
      assert_receive {^server, {:data, {:eol, refusal}}}, 30_000

      assert %{"id" => nil, "error" => %{"code" => -32_600, "message" => message}} =
               JSON.decode!(refusal)

      assert message =~ "#{@max_line_bytes}-byte line limit"

      memory = TestFixtures.request("memory", "tools/call", %{"name" => "memory"})
      true = Port.command(server, "\n" <> JSON.encode!(memory) <> "\n")
      assert_receive {^server, {:data, {:eol, response}}}, 30_000

      assert %{"id" => "memory", "result" => %{"structuredContent" => structured}} =
               JSON.decode!(response)

      %{"growth" => growth} = structured

      assert growth < 16 * @max_line_bytes,
             "peak memory grew by #{growth} bytes for a #{@line_megabytes} MB line"
    end
  end
end
