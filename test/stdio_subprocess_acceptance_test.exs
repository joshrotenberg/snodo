defmodule MCP.Transport.StdioSubprocessAcceptanceTest do
  use ExUnit.Case, async: true

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
        "mcp_ex_stdio_stderr_#{System.unique_integer([:positive])}.log"
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
end
