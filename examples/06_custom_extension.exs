defmodule Examples.CustomExtension.Greeting do
  @moduledoc false
  @behaviour MCP.Extension

  alias MCP.Error
  alias MCP.Extension.Method
  alias MCP.Result

  @id "dev.example/greeting"

  @impl true
  def id, do: @id

  @impl true
  def methods do
    [
      Method.new!(
        protocol_version: "2026-07-28",
        name: "dev.example/greet",
        operation: :greet
      )
    ]
  end

  @impl true
  def negotiate(
        %{"case" => casing, "punctuation" => punctuation},
        %{"prefix" => prefix}
      )
      when casing in ["plain", "upper"] and is_binary(punctuation) and is_binary(prefix) do
    {:ok, %{"case" => casing, "prefix" => prefix, "punctuation" => punctuation}}
  end

  def negotiate(_client_settings, _server_settings), do: :not_negotiated

  @impl true
  def validate_operation(:greet, %{"name" => name}, _context)
      when is_binary(name) and name != "",
      do: :ok

  def validate_operation(:greet, _params, _context) do
    {:error, Error.invalid_params("name must be a non-empty string")}
  end

  @impl true
  def dispatch(:greet, %{"name" => name}, context) do
    settings = Map.fetch!(context.extensions, @id)
    greeting = "#{settings["prefix"]}, #{name}#{settings["punctuation"]}"

    message =
      case settings["case"] do
        "upper" -> String.upcase(greeting)
        "plain" -> greeting
      end

    {:ok, Result.structured(%{"message" => message})}
  end

  @impl true
  def shape_result(:greet, %Result{} = result, context) do
    %{
      "message" => result.value["message"],
      "contextExtensions" => context.extensions
    }
  end

  @impl true
  def shape_error(%Error{} = error, _context) do
    %{
      "code" => error.code,
      "message" => "Greeting extension rejected the request",
      "data" => %{"reason" => error.message}
    }
  end
end

defmodule Examples.CustomExtension.CoreCollision do
  @moduledoc false
  @behaviour MCP.Extension

  alias MCP.Error
  alias MCP.Extension.Method
  alias MCP.Result

  @impl true
  def id, do: "dev.example/core-collision"

  @impl true
  def methods do
    [
      Method.new!(
        protocol_version: "2026-07-28",
        name: "tools/list",
        operation: :collision
      )
    ]
  end

  @impl true
  def negotiate(_client_settings, _server_settings), do: :not_negotiated

  @impl true
  def validate_operation(_operation, _params, _context), do: :ok

  @impl true
  def dispatch(_operation, _params, _context), do: {:ok, Result.raw(%{})}

  @impl true
  def shape_result(_operation, _result, _context), do: %{}

  @impl true
  def shape_error(%Error{} = error, _context), do: Error.to_json_rpc(error)
end

defmodule Examples.CustomExtension.Server do
  @moduledoc false

  use MCP.Server,
    name: "custom-extension-example",
    version: "0.1.0",
    protocols: [MCP.Protocol.V2026_07_28],
    extensions: [Examples.CustomExtension.Greeting],
    capabilities: %{
      "extensions" => %{
        "dev.example/greeting" => %{"prefix" => "Welcome"}
      }
    }
end

defmodule Examples.CustomExtension.CollisionServer do
  @moduledoc false

  use MCP.Server,
    name: "collision-example",
    version: "0.1.0",
    protocols: [MCP.Protocol.V2026_07_28],
    extensions: [Examples.CustomExtension.CoreCollision]
end

defmodule Examples.CustomExtension.Runner do
  @moduledoc false

  alias Examples.CustomExtension.CollisionServer
  alias Examples.CustomExtension.Greeting
  alias Examples.CustomExtension.Server

  @protocol "2026-07-28"

  def run(mode) do
    runtime = Server.runtime()
    discovery = dispatch(runtime, "discover", "server/discover")
    server_settings = get_in(discovery, ["result", "capabilities", "extensions", Greeting.id()])

    ensure(
      server_settings == %{"prefix" => "Welcome"},
      "the DSL-installed extension was not advertised"
    )

    client_settings = %{"case" => "upper", "punctuation" => "!"}
    client_capabilities = %{"extensions" => %{Greeting.id() => client_settings}}

    success =
      dispatch(
        runtime,
        "greet",
        "dev.example/greet",
        %{"name" => "Ada"},
        client_capabilities
      )

    negotiated = %{
      "case" => "upper",
      "prefix" => "Welcome",
      "punctuation" => "!"
    }

    ensure(get_in(success, ["result", "message"]) == "WELCOME, ADA!", "negotiation was ignored")

    ensure(
      get_in(success, ["result", "contextExtensions"]) == %{Greeting.id() => negotiated},
      "negotiated settings did not reach Context.extensions"
    )

    invalid =
      dispatch(
        runtime,
        "invalid",
        "dev.example/greet",
        %{"name" => ""},
        client_capabilities
      )

    ensure(get_in(invalid, ["error", "code"]) == -32_602, "extension validation was bypassed")

    ensure(
      get_in(invalid, ["error", "message"]) == "Greeting extension rejected the request",
      "extension error shaping was bypassed"
    )

    unnegotiated =
      dispatch(runtime, "unnegotiated", "dev.example/greet", %{"name" => "Ada"})

    ensure(
      get_in(unnegotiated, ["error", "code"]) == -32_601,
      "an unnegotiated extension method must be method-not-found"
    )

    collision_message = collision_message()

    ensure(
      String.contains?(collision_message, "collides with the 2026-07-28 core catalog"),
      "a core-method collision must be rejected during registration"
    )

    print_summary(mode, server_settings)
  end

  defp dispatch(runtime, id, method, params \\ %{}, client_capabilities \\ %{}) do
    {:ok, response} =
      MCP.Test.dispatch(runtime,
        id: id,
        protocol: @protocol,
        method: method,
        params: params,
        client_capabilities: client_capabilities
      )

    response
  end

  defp collision_message do
    CollisionServer.runtime()
    raise "colliding extension registration unexpectedly succeeded"
  rescue
    error in ArgumentError -> Exception.message(error)
  end

  defp ensure(true, _message), do: :ok
  defp ensure(false, message), do: raise(message)

  defp print_summary(:check, _server_settings), do: IO.puts("06_custom_extension: ok")

  defp print_summary(:walkthrough, server_settings) do
    IO.puts("Negotiated out-of-tree extension")
    IO.puts("  installed by DSL: #{Greeting.id()}")
    IO.puts("  advertised server settings: #{inspect(server_settings)}")
    IO.puts("  negotiated result: WELCOME, ADA!")
    IO.puts("  safeguards: validation, method-not-found, and core collision rejection")
  end
end

case System.argv() do
  ["--check"] -> Examples.CustomExtension.Runner.run(:check)
  [] -> Examples.CustomExtension.Runner.run(:walkthrough)
  _arguments -> raise "usage: mix run examples/06_custom_extension.exs [--check]"
end
