defmodule StdioConcurrency.Slow do
  @moduledoc false

  use MCP.Tool,
    name: "slow",
    description: "Wait for cancellation after crossing a synchronization barrier"

  input_schema(%{
    "type" => "object",
    "properties" => %{"controlPort" => %{"type" => "integer"}},
    "required" => ["controlPort"],
    "additionalProperties" => false
  })

  @impl true
  def call(%{"controlPort" => port}, _context) do
    options = [:binary, active: false, packet: :line]
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, options, 2_000)
    :ok = :gen_tcp.send(socket, "slow-started\n")

    result = :gen_tcp.recv(socket, 0, :infinity)
    :gen_tcp.close(socket)

    {:error, {:slow_handler_was_not_cancelled, result}}
  end
end

defmodule StdioConcurrency.Echo do
  @moduledoc false

  use MCP.Tool,
    name: "echo",
    description: "Return text immediately"

  input_schema(%{
    "type" => "object",
    "properties" => %{"text" => %{"type" => "string"}},
    "required" => ["text"],
    "additionalProperties" => false
  })

  @impl true
  def call(%{"text" => text}, _context), do: {:ok, MCP.Result.text(text)}
end

defmodule StdioConcurrency.Server do
  @moduledoc false

  use MCP.Server,
    name: "stdio-concurrency-example",
    version: "0.1.0",
    protocols: [MCP.Protocol.V2026_07_28]

  tool(StdioConcurrency.Slow)
  tool(StdioConcurrency.Echo)
end

defmodule StdioConcurrency.Example do
  @moduledoc false

  alias MCP.Protocol.V2026_07_28, as: Protocol

  @timeout 15_000

  def serve do
    case MCP.Transport.Stdio.serve(StdioConcurrency.Server.runtime(), max_concurrency: 2) do
      :ok -> :ok
      {:error, reason} -> raise "stdio server failed: #{inspect(reason)}"
    end
  end

  def run(check?) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, ip: {127, 0, 0, 1}])

    {:ok, {_address, control_port}} = :inet.sockname(listener)

    try do
      with_fifo(fn fifo -> exercise_subprocess(fifo, listener, control_port, check?) end)
    after
      :gen_tcp.close(listener)
    end
  end

  defp exercise_subprocess(fifo, listener, control_port, check?) do
    subprocess = start_subprocess(fifo)

    try do
      input = File.open!(fifo, [:write, :binary])

      try do
        send_message(input, call_request("cancel-me", "slow", %{"controlPort" => control_port}))

        {:ok, control_socket} = :gen_tcp.accept(listener, @timeout)

        try do
          {:ok, "slow-started\n"} = :gen_tcp.recv(control_socket, 0, @timeout)

          send_message(input, call_request("fast", "echo", %{"text" => "fast"}))
          {fast_line, buffer} = next_line(subprocess, "")
          fast_response = decode_protocol_line!(fast_line)
          assert!(fast_response["id"] == "fast", "fast response arrived before slow")

          send_message(input, cancellation("cancel-me"))

          assert!(
            :gen_tcp.recv(control_socket, 0, @timeout) == {:error, :closed},
            "cancellation terminated only the slow handler"
          )

          send_message(input, call_request("after-cancel", "echo", %{"text" => "still alive"}))
          {follow_up_line, buffer} = next_line(subprocess, buffer)
          follow_up = decode_protocol_line!(follow_up_line)
          assert!(follow_up["id"] == "after-cancel", "follow-up request succeeded")
          assert!(text(follow_up) == "still alive", "follow-up result remained correct")

          :ok = File.close(input)

          {remaining_lines, status} = collect_exit(subprocess, buffer)
          all_lines = [fast_line, follow_up_line | remaining_lines]
          messages = Enum.map(all_lines, &decode_protocol_line!/1)

          assert!(status == 0, "stdio subprocess exited cleanly")

          assert!(
            Enum.map(messages, & &1["id"]) == ["fast", "after-cancel"],
            "cancelled ID had no response"
          )

          assert!(
            Enum.all?(messages, &(&1["jsonrpc"] == "2.0")),
            "stdout contained only protocol messages"
          )

          print_result(check?, messages)
        after
          :gen_tcp.close(control_socket)
        end
      after
        close_file(input)
      end
    after
      close_port(subprocess)
    end
  end

  defp start_subprocess(fifo) do
    shell = System.find_executable("sh") || raise "sh executable was not found"
    elixir = System.find_executable("elixir") || raise "elixir executable was not found"
    ebin = MCP.Server |> :code.which() |> List.to_string() |> Path.dirname()
    script = Path.expand(__ENV__.file)
    command = ~S(exec "$1" -pa "$2" "$3" --server < "$4")

    Port.open(
      {:spawn_executable, shell},
      [
        :binary,
        :exit_status,
        :use_stdio,
        :eof,
        {:args, ["-c", command, "stdio-concurrency", elixir, ebin, script, fifo]}
      ]
    )
  end

  defp with_fifo(fun) do
    directory =
      Path.join(
        System.tmp_dir!(),
        "mcp_ex_stdio_example_#{System.unique_integer([:positive, :monotonic])}"
      )

    fifo = Path.join(directory, "requests.fifo")
    File.mkdir!(directory)

    try do
      mkfifo = System.find_executable("mkfifo") || raise "mkfifo executable was not found"
      {output, status} = System.cmd(mkfifo, [fifo], stderr_to_stdout: true)
      assert!(status == 0, "mkfifo failed: #{String.trim(output)}")
      fun.(fifo)
    after
      File.rm(fifo)
      File.rmdir(directory)
    end
  end

  defp call_request(id, name, arguments) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{
        "name" => name,
        "arguments" => arguments,
        "_meta" => Protocol.request_metadata(%{})
      }
    }
  end

  defp cancellation(request_id) do
    %{
      "jsonrpc" => "2.0",
      "method" => "notifications/cancelled",
      "params" => %{"requestId" => request_id, "reason" => "example cancellation"}
    }
  end

  defp send_message(input, message) do
    :ok = IO.binwrite(input, [JSON.encode!(message), "\n"])
  end

  defp next_line(port, buffer) do
    case take_line(buffer) do
      {:ok, line, rest} ->
        {line, rest}

      :incomplete ->
        receive do
          {^port, {:data, data}} -> next_line(port, buffer <> data)
          {^port, {:exit_status, status}} -> raise "subprocess exited early with status #{status}"
          {^port, :eof} -> raise "subprocess closed stdout before a response"
        after
          @timeout -> raise "timed out waiting for a stdio response"
        end
    end
  end

  defp take_line(buffer) do
    case :binary.split(buffer, "\n") do
      [line, rest] -> {:ok, line, rest}
      [_incomplete] -> :incomplete
    end
  end

  defp collect_exit(port, buffer) do
    collect_exit(port, buffer, [], nil, false)
  end

  defp collect_exit(_port, buffer, lines, status, true) when is_integer(status) do
    trailing = String.trim(buffer)
    lines = if trailing == "", do: lines, else: [trailing | lines]
    {Enum.reverse(lines), status}
  end

  defp collect_exit(port, buffer, lines, status, eof?) do
    receive do
      {^port, {:data, data}} ->
        {complete, rest} = split_complete_lines(buffer <> data)
        collect_exit(port, rest, Enum.reverse(complete, lines), status, eof?)

      {^port, {:exit_status, exit_status}} ->
        collect_exit(port, buffer, lines, exit_status, eof?)

      {^port, :eof} ->
        collect_exit(port, buffer, lines, status, true)
    after
      @timeout -> raise "timed out waiting for the stdio subprocess to exit"
    end
  end

  defp split_complete_lines(buffer) do
    parts = :binary.split(buffer, "\n", [:global])
    {Enum.drop(parts, -1), List.last(parts)}
  end

  defp decode_protocol_line!(line) do
    case JSON.decode(line) do
      {:ok, %{"jsonrpc" => "2.0"} = message} -> message
      {:ok, other} -> raise "stdout line was not a JSON-RPC message: #{inspect(other)}"
      {:error, reason} -> raise "stdout line was not JSON: #{inspect(reason)}"
    end
  end

  defp text(response), do: get_in(response, ["result", "content", Access.at(0), "text"])

  defp close_file(input) do
    if Process.alive?(input), do: File.close(input)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  catch
    :error, :badarg -> :ok
  end

  defp assert!(true, _label), do: :ok
  defp assert!(false, label), do: raise("check failed: #{label}")

  defp print_result(true, _messages), do: IO.puts("04_stdio_concurrency: ok")

  defp print_result(false, messages) do
    ids = Enum.map_join(messages, ", ", & &1["id"])
    IO.puts("The fast request completed while the slow request was blocked.")
    IO.puts("Cancellation suppressed the slow response; observed IDs: #{ids}.")
    IO.puts("The subprocess then reached EOF and exited normally.")
  end
end

case System.argv() do
  [] -> StdioConcurrency.Example.run(false)
  ["--check"] -> StdioConcurrency.Example.run(true)
  ["--server"] -> StdioConcurrency.Example.serve()
  _arguments -> raise "usage: mix run examples/04_stdio_concurrency.exs [--check]"
end
