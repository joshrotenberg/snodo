defmodule Examples.HTTPTools.Echo do
  @moduledoc false

  use MCP.Tool,
    name: "echo",
    description: "Echo text through the native HTTP transport"

  input_schema(%{
    "type" => "object",
    "properties" => %{"text" => %{"type" => "string"}},
    "required" => ["text"]
  })

  @impl true
  def call(%{"text" => text}, _context), do: {:ok, MCP.Result.text(text)}
end

defmodule Examples.HTTPTools.Server do
  @moduledoc false

  use MCP.Server,
    name: "http-tools-example",
    version: "0.1.0",
    protocols: [MCP.Protocol.V2026_07_28]

  tool(Examples.HTTPTools.Echo)
end

# This tiny client keeps the walkthrough dependency-free. The released-client
# and frozen official-suite probes live in interop/official_client and
# conformance/README.md respectively.
defmodule Examples.HTTPTools.Client do
  @moduledoc false

  @protocol "2026-07-28"
  @receive_timeout 2_000

  def post(port, path, raw, opts \\ []) do
    headers = request_headers(port, raw, opts)
    request(port, "POST", path, headers, JSON.encode!(raw))
  end

  def get(port, path), do: request(port, "GET", path, [], "")

  def request_headers(port, raw, opts \\ []) do
    method_header = Keyword.get(opts, :method_header, raw["method"])

    headers = [
      {"Content-Type", "application/json"},
      {"Accept", "application/json, text/event-stream"},
      {"Origin", "http://127.0.0.1:#{port}"},
      {"MCP-Protocol-Version", @protocol},
      {"Mcp-Method", method_header}
    ]

    case Keyword.get(opts, :name_header, :automatic) do
      :automatic -> maybe_add_name_header(headers, raw)
      nil -> headers
      value -> headers ++ [{"Mcp-Name", value}]
    end
  end

  defp maybe_add_name_header(headers, %{"method" => "tools/call"} = raw) do
    headers ++ [{"Mcp-Name", get_in(raw, ["params", "name"])}]
  end

  defp maybe_add_name_header(headers, _raw), do: headers

  defp request(port, method, path, headers, body) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], @receive_timeout)

    try do
      :ok = :gen_tcp.send(socket, encode_request(port, method, path, headers, body))
      socket |> receive_all("") |> parse_response()
    after
      :gen_tcp.close(socket)
    end
  end

  defp encode_request(port, method, path, headers, body) do
    complete_headers = [
      {"Host", "127.0.0.1:#{port}"},
      {"Content-Length", Integer.to_string(byte_size(body))}
      | headers
    ]

    header_lines =
      Enum.map(complete_headers, fn {name, value} -> [name, ": ", value, "\r\n"] end)

    [method, " ", path, " HTTP/1.1\r\n", header_lines, "\r\n", body]
  end

  defp receive_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, @receive_timeout) do
      {:ok, chunk} -> receive_all(socket, acc <> chunk)
      {:error, :closed} -> acc
      {:error, reason} -> raise "HTTP response failed: #{inspect(reason)}"
    end
  end

  defp parse_response(response) do
    [head, body] = :binary.split(response, "\r\n\r\n")
    [status_line | header_lines] = :binary.split(head, "\r\n", [:global])
    [_version, status | _reason] = String.split(status_line, " ")

    headers =
      Map.new(header_lines, fn line ->
        [name, value] = :binary.split(line, ":")
        {String.downcase(name), String.trim(value)}
      end)

    %{status: String.to_integer(status), headers: headers, body: body}
  end
end

defmodule Examples.HTTPTools.Runner do
  @moduledoc false

  alias Examples.HTTPTools.Client
  alias Examples.HTTPTools.Server
  alias MCP.Protocol.V2026_07_28
  alias MCP.Transport.StreamableHTTP.Server, as: HTTPServer

  @protocol "2026-07-28"

  def run(mode) do
    {:ok, listener} = HTTPServer.start_link(runtime: Server.runtime(), port: 0)
    {{127, 0, 0, 1}, port, "/mcp"} = HTTPServer.address(listener)

    summary =
      try do
        exercise(port, HTTPServer.url(listener))
      after
        if Process.alive?(listener), do: GenServer.stop(listener)
      end

    print_summary(mode, summary)
  end

  defp exercise(port, url) do
    discover = request("discover", "server/discover")
    discover_response = Client.post(port, "/mcp", discover)
    discover_body = decode_json(discover_response)

    ensure(discover_response.status == 200, "server/discover must return HTTP 200")

    ensure(
      @protocol in get_in(discover_body, ["result", "supportedVersions"]),
      "server/discover must advertise the pinned protocol"
    )

    list = request("list", "tools/list")
    list_response = Client.post(port, "/mcp", list)
    list_body = decode_json(list_response)

    ensure(list_response.status == 200, "tools/list must return HTTP 200")
    ensure(get_in(list_body, ["result", "tools", Access.at(0), "name"]) == "echo", "tool missing")

    call =
      request("call", "tools/call", %{
        "name" => "echo",
        "arguments" => %{"text" => "hello over HTTP"}
      })

    call_response = Client.post(port, "/mcp", call)
    call_body = decode_json(call_response)

    ensure(call_response.status == 200, "tools/call must return HTTP 200")

    ensure(
      get_in(call_body, ["result", "content", Access.at(0)]) ==
        %{"type" => "text", "text" => "hello over HTTP"},
      "tools/call returned an unexpected result"
    )

    for response <- [discover_response, list_response, call_response] do
      ensure(
        not Map.has_key?(response.headers, "mcp-session-id"),
        "the stateless transport must not mint a session"
      )
    end

    missing_name = Client.post(port, "/mcp", call, name_header: nil)
    missing_name_body = decode_json(missing_name)
    ensure(missing_name.status == 400, "a missing Mcp-Name header must return HTTP 400")

    ensure(
      get_in(missing_name_body, ["error", "code"]) == -32_020,
      "a missing mirrored header must use the transport header error"
    )

    wrong_method = Client.post(port, "/mcp", discover, method_header: "tools/list")
    wrong_method_body = decode_json(wrong_method)
    ensure(wrong_method.status == 400, "a mismatched Mcp-Method header must return HTTP 400")

    ensure(
      get_in(wrong_method_body, ["error", "code"]) == -32_020,
      "a mismatched mirrored header must use the transport header error"
    )

    wrong_path = Client.post(port, "/elsewhere", list)
    ensure(wrong_path.status == 404, "an unrelated path must return HTTP 404")

    wrong_method_response = Client.get(port, "/mcp")
    ensure(wrong_method_response.status == 405, "GET must return HTTP 405")
    ensure(wrong_method_response.headers["allow"] == "POST", "HTTP 405 must advertise POST")

    %{url: url, tool: "echo", value: "hello over HTTP"}
  end

  defp request(id, method, params \\ %{}) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => Map.put(params, "_meta", V2026_07_28.request_metadata(%{}))
    }
  end

  defp decode_json(%{body: body}) do
    case JSON.decode(body) do
      {:ok, decoded} -> decoded
      {:error, reason} -> raise "expected a JSON response, got #{inspect(reason)}"
    end
  end

  defp ensure(true, _message), do: :ok
  defp ensure(false, message), do: raise(message)

  defp print_summary(:check, _summary), do: IO.puts("05_http_tools: ok")

  defp print_summary(:walkthrough, summary) do
    IO.puts("Native Streamable HTTP")
    IO.puts("  endpoint: #{summary.url}")
    IO.puts("  discovery/list/call: #{summary.tool} -> #{inspect(summary.value)}")
    IO.puts("  admission: required media and mirrored headers enforced")
    IO.puts("  session: none minted; listener stopped cleanly")
    IO.puts("  external probes: interop/official_client and conformance/README.md")
  end
end

case System.argv() do
  ["--check"] -> Examples.HTTPTools.Runner.run(:check)
  [] -> Examples.HTTPTools.Runner.run(:walkthrough)
  _arguments -> raise "usage: mix run examples/05_http_tools.exs [--check]"
end
