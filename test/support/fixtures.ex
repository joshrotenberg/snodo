defmodule MCPEx.TestTools.Echo do
  use MCP.Tool,
    name: "echo",
    description: "Echo text"

  input_schema(%{
    "$schema" => "https://json-schema.org/draft/2020-12/schema",
    "$id" => "https://example.test/schemas/echo",
    "$defs" => %{"text" => %{"type" => "string", "x-vendor-nested" => [true, 7, nil]}},
    "type" => "object",
    "properties" => %{
      "text" => %{"$ref" => "#/$defs/text", "x-mcp-header" => "Echo-Text"},
      "mode" => %{"oneOf" => [%{"const" => "plain"}, %{"const" => "loud"}]},
      "delayMs" => %{"type" => "integer", "minimum" => 0}
    },
    "if" => %{"properties" => %{"mode" => %{"const" => "loud"}}},
    "then" => %{"required" => ["text"]},
    "else" => %{},
    "unevaluatedProperties" => false,
    "required" => ["text"]
  })

  @impl true
  def call(%{"text" => text} = arguments, _context) do
    delay = Map.get(arguments, "delayMs", 0)
    if delay > 0, do: Process.sleep(delay)
    {:ok, MCP.Result.text(text)}
  end
end

defmodule MCPEx.TestTools.ComplexSchema do
  use MCP.Tool, name: "complex_schema"

  input_schema(%{
    "type" => "object",
    "properties" => %{},
    "additionalProperties" => false
  })

  output_schema(%{
    "type" => "array",
    "items" => %{"type" => "string"},
    "x-output-vendor" => %{"preserve" => true}
  })

  @impl true
  def call(_arguments, _context), do: {:ok, MCP.Result.structured([])}
end

defmodule MCPEx.TestTools.ContextEcho do
  use MCP.Tool, name: "context_echo"

  @impl true
  def call(_arguments, context) do
    {:ok,
     MCP.Result.structured(%{
       "metadata" => context.metadata,
       "session" => context.session,
       "protocolVersion" => context.protocol_version,
       "clientCapabilities" => context.client_capabilities
     })}
  end
end

defmodule MCPEx.TestTools.Structured do
  use MCP.Tool, name: "structured"

  @impl true
  def call(%{"value" => value}, _context), do: {:ok, MCP.Result.structured(value)}
end

defmodule MCPEx.TestTools.Failing do
  use MCP.Tool, name: "failing"

  @impl true
  def call(_arguments, _context), do: {:error, "Actionable domain failure"}
end

defmodule MCPEx.TestTools.Raising do
  use MCP.Tool, name: "raising"

  @impl true
  def call(_arguments, _context), do: raise("secret implementation detail")
end

defmodule MCPEx.TestTools.NotificationProbe do
  use MCP.Tool, name: "notification_probe"

  @impl true
  def call(%{"owner" => owner}, _context) do
    send(owner, :notification_probe_called)
    {:ok, MCP.Result.text("called")}
  end
end

defmodule MCPEx.TestTools.InvalidStructuredOutput do
  use MCP.Tool, name: "invalid_structured_output"

  output_schema(%{
    "type" => "object",
    "required" => ["ok"]
  })

  @impl true
  def call(_arguments, _context), do: {:ok, MCP.Result.structured(%{"wrong" => true})}
end

defmodule MCPEx.TestTools.InvalidWireResult do
  use MCP.Tool, name: "invalid_wire_result"

  @impl true
  def call(_arguments, _context) do
    {:ok, MCP.Result.raw(%{"content" => [], "nonJson" => self()})}
  end
end

defmodule MCPEx.TestTools.InvalidInputSchema do
  @behaviour MCP.Tool

  @impl true
  def name, do: "invalid_input_schema"

  @impl true
  def description, do: nil

  @impl true
  def input_schema, do: %{"type" => "array"}

  @impl true
  def output_schema, do: nil

  @impl true
  def annotations, do: %{}

  @impl true
  def call(_arguments, _context), do: {:ok, MCP.Result.text("unreachable")}
end

defmodule MCPEx.RequiredKeysValidator do
  @behaviour MCP.Schema.Validator

  @impl true
  def validate(value, %{"type" => "object"}) when not is_map(value),
    do: {:error, :expected_object}

  def validate(value, %{"type" => "array"}) when not is_list(value),
    do: {:error, :expected_array}

  def validate(value, %{"required" => required}) when is_map(value) and is_list(required) do
    case Enum.reject(required, &Map.has_key?(value, &1)) do
      [] -> :ok
      missing -> {:error, {:missing_required, missing}}
    end
  end

  def validate(_value, _schema), do: :ok
end

defmodule MCPEx.RejectingInputValidator do
  @behaviour MCP.Schema.Validator

  # Rejects any tool input, so a call carrying every required argument still
  # exercises the plugged validator rather than the router's own check.
  @impl true
  def validate(value, %{"$id" => "https://example.test/schemas/echo"}) when is_map(value),
    do: {:error, :rejected_by_application}

  def validate(_value, _schema), do: :ok
end

defmodule MCPEx.TestTools.Trapping do
  use MCP.Tool, name: "trapping"

  @impl true
  def call(%{"token" => token}, context) do
    Process.flag(:trap_exit, true)
    owner = :global.whereis_name({__MODULE__, token})
    send(owner, {:trapping_entered, self(), context.cancellation})

    receive do
      :finish -> {:ok, MCP.Result.text("finished")}
    after
      10_000 -> {:ok, MCP.Result.text("timed out")}
    end
  end
end

defmodule MCPEx.TestTools.Barrier do
  use MCP.Tool, name: "barrier"

  @impl true
  def call(%{"owner" => owner, "index" => index}, _context) do
    send(owner, {:entered, index, self()})

    receive do
      {:release, ^index} -> {:ok, MCP.Result.structured(%{"index" => index})}
    after
      5_000 -> {:error, "barrier timeout"}
    end
  end
end

defmodule MCPEx.TestTools.EchoCollision do
  use MCP.Tool, name: "echo"

  @impl true
  def call(_arguments, _context), do: {:ok, MCP.Result.text("collision")}
end

defmodule MCPEx.FutureDialect do
  @behaviour MCP.Protocol

  alias MCP.Context
  alias MCP.Envelope
  alias MCP.Error
  alias MCP.Protocol
  alias MCP.Protocol.Profile
  alias MCP.Protocol.Profile.Method
  alias MCP.Result
  alias MCP.Transport.Context, as: TransportContext
  alias MCP.Transport.Policy

  @version "2099-01-01"
  @version_key "com.acme/protocolVersion"
  @capabilities_key "com.acme/clientCapabilities"

  @profile Profile.new!(
             version: @version,
             status: :experimental,
             scope: :implemented_slice,
             era: :stateless,
             batching: :forbidden,
             request_metadata: %{request: :required, notification: :optional},
             methods: [
               Method.new!(
                 name: "acme/echo",
                 kind: :request,
                 directions: [:client_to_server],
                 params: :required,
                 capability: "tools",
                 status: :implemented
               )
             ],
             capabilities: ["tools"],
             transports: %{direct: :tested, stdio: :unmeasured},
             limitations: %{fixture_only: :unsupported},
             specification: "https://example.test/mcp/2099-01-01"
           )

  @impl true
  def profile, do: @profile

  @impl true
  def version, do: @version

  @impl true
  def era, do: :stateless

  @impl true
  def detect(%Envelope{kind: :request} = envelope) do
    if Map.get(Protocol.request_meta(envelope), @version_key) == @version,
      do: :exact,
      else: false
  end

  def detect(%Envelope{}), do: false

  @impl true
  def decode_request(raw, %TransportContext{} = transport), do: Envelope.decode(raw, transport)

  @impl true
  def build_context(%Envelope{} = envelope, runtime) do
    {:ok,
     %Context{
       protocol_version: @version,
       protocol: __MODULE__,
       transport: envelope.transport,
       request_id: envelope.id,
       session: nil,
       server_info: runtime.server_info,
       server_capabilities: runtime.capabilities,
       metadata: Protocol.request_meta(envelope)
     }}
  end

  @impl true
  def resolve_operation(%Envelope{method: "acme/echo", params: %{"name" => name}}),
    do: {:ok, {:tools_call, name}}

  def resolve_operation(%Envelope{}), do: :not_handled

  @impl true
  def validate_operation(_operation, _params, %Context{}), do: :ok

  @impl true
  def shape_result(_operation, %Result{} = result, _context) do
    %{"resultType" => "complete", "futureValue" => result.value}
  end

  @impl true
  def shape_error(%Error{} = error, _context), do: Error.to_json_rpc(error)

  @impl true
  def transport_policy(_envelope), do: %Policy{}

  @impl true
  def server_discovery(_runtime), do: :unsupported

  @impl true
  def request_metadata(capabilities) do
    %{@version_key => @version, @capabilities_key => capabilities}
  end
end

defmodule MCPEx.ProfileDriftDialect do
  @moduledoc false
  @behaviour MCP.Protocol

  alias MCP.Envelope
  alias MCP.Protocol.Profile
  alias MCP.Protocol.Profile.Method

  @profile Profile.new!(
             version: "2099-01-01",
             status: :experimental,
             scope: :implemented_slice,
             era: :stateless,
             batching: :forbidden,
             request_metadata: %{request: :required, notification: :optional},
             methods: [
               Method.new!(
                 name: "acme/echo",
                 kind: :request,
                 directions: [:client_to_server],
                 params: :required,
                 capability: "tools",
                 status: :unsupported
               )
             ],
             capabilities: ["tools"],
             transports: %{direct: :tested, stdio: :unmeasured},
             limitations: %{fixture_only: :unsupported},
             specification: "https://example.test/mcp/2099-01-01"
           )

  @impl true
  def profile, do: @profile

  @impl true
  defdelegate version(), to: MCPEx.FutureDialect

  @impl true
  defdelegate era(), to: MCPEx.FutureDialect

  @impl true
  defdelegate detect(envelope), to: MCPEx.FutureDialect

  @impl true
  defdelegate decode_request(raw, transport), to: MCPEx.FutureDialect

  @impl true
  defdelegate build_context(envelope, runtime), to: MCPEx.FutureDialect

  @impl true
  def resolve_operation(%Envelope{method: method, params: %{"name" => name}})
      when method in ["acme/echo", "acme/hidden"] do
    {:ok, {:tools_call, name}}
  end

  def resolve_operation(envelope), do: MCPEx.FutureDialect.resolve_operation(envelope)

  @impl true
  defdelegate validate_operation(operation, params, context), to: MCPEx.FutureDialect

  @impl true
  defdelegate shape_result(operation, result, context), to: MCPEx.FutureDialect

  @impl true
  defdelegate shape_error(error, context), to: MCPEx.FutureDialect

  @impl true
  defdelegate transport_policy(envelope), to: MCPEx.FutureDialect

  @impl true
  defdelegate server_discovery(runtime), to: MCPEx.FutureDialect

  @impl true
  defdelegate request_metadata(capabilities), to: MCPEx.FutureDialect
end

defmodule MCPEx.TestFixtures do
  alias MCP.Protocol.V2026_07_28
  alias MCP.Router
  alias MCP.Server.Runtime

  @default_tools [
    MCPEx.TestTools.Echo,
    MCPEx.TestTools.ComplexSchema,
    MCPEx.TestTools.ContextEcho,
    MCPEx.TestTools.Structured,
    MCPEx.TestTools.Failing,
    MCPEx.TestTools.Raising
  ]

  def runtime(opts \\ []) do
    tools = Keyword.get(opts, :tools, @default_tools)
    prompts = Keyword.get(opts, :prompts, [])
    resources = Keyword.get(opts, :resources, [])
    protocols = Keyword.get(opts, :protocols, [V2026_07_28])

    router =
      tools
      |> Enum.reduce(Router.new(), &Router.register_tool(&2, &1))
      |> then(fn router ->
        Enum.reduce(prompts, router, &Router.register_prompt(&2, &1))
      end)
      |> then(fn router ->
        Enum.reduce(resources, router, &Router.register_resource(&2, &1))
      end)

    runtime_options = [
      router: router,
      protocols: protocols,
      extensions: Keyword.get(opts, :extensions, []),
      server_info: %{"name" => "mcp-ex-spike", "version" => "0.1.0"},
      schema_validator: Keyword.get(opts, :schema_validator, MCP.Schema.Validator.Passthrough),
      instructions: Keyword.get(opts, :instructions),
      discovery_cache: Keyword.get(opts, :discovery_cache, []),
      tools_cache: Keyword.get(opts, :tools_cache, []),
      prompts_cache: Keyword.get(opts, :prompts_cache, []),
      resources_cache: Keyword.get(opts, :resources_cache, []),
      pagination: Keyword.get(opts, :pagination, []),
      subscription_source: Keyword.get(opts, :subscription_source),
      instrumentation: Keyword.get(opts, :instrumentation)
    ]

    runtime_options =
      case Keyword.fetch(opts, :capabilities) do
        {:ok, capabilities} -> Keyword.put(runtime_options, :capabilities, capabilities)
        :error -> runtime_options
      end

    Runtime.new(runtime_options)
  end

  def metadata(version \\ "2026-07-28", extra \\ %{}) do
    Map.merge(
      MCP.Protocol.V2026_07_28.request_metadata(%{})
      |> Map.put(MCP.Protocol.V2026_07_28.protocol_version_key(), version),
      extra
    )
  end

  def request(id, method, params \\ %{}) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => Map.put_new(params, "_meta", metadata())
    }
  end
end

defmodule MCPEx.TestServer do
  use MCP.Server,
    name: "dsl-server",
    version: "1.2.3",
    protocols: [MCP.Protocol.V2026_07_28],
    tools_cache: [ttl_ms: 5, scope: "private"],
    prompts_cache: [ttl_ms: 20, scope: "private"],
    resources_cache: [ttl_ms: 30, scope: "public"],
    pagination: [page_size: 2]

  tool(MCPEx.TestTools.ContextEcho)
  tool(MCPEx.TestTools.Echo)
  prompt(MCPEx.TestPrompts.PackageAnalysis)
  resource(MCPEx.TestResources.StaticText)
end

defmodule MCPEx.TestInput do
  def start_link do
    pid = spawn_link(fn -> loop(:queue.new(), nil, false) end)
    {:ok, pid}
  end

  def push(device, line) when is_binary(line), do: send(device, {:push, line})
  def eof(device), do: send(device, :eof)

  defp loop(queue, waiter, eof?) do
    receive do
      {:push, line} ->
        case waiter do
          {from, reply_as} ->
            io_reply(from, reply_as, line)
            loop(queue, nil, eof?)

          nil ->
            loop(:queue.in(line, queue), nil, eof?)
        end

      :eof ->
        if waiter && :queue.is_empty(queue) do
          {from, reply_as} = waiter
          io_reply(from, reply_as, :eof)
        else
          loop(queue, waiter, true)
        end

      {:io_request, from, reply_as, {:get_line, _encoding, _prompt}} ->
        case :queue.out(queue) do
          {{:value, line}, remaining} ->
            io_reply(from, reply_as, line)
            loop(remaining, nil, eof?)

          {:empty, _queue} when eof? ->
            io_reply(from, reply_as, :eof)

          {:empty, empty_queue} ->
            loop(empty_queue, {from, reply_as}, false)
        end

      {:io_request, from, reply_as, _unsupported} ->
        io_reply(from, reply_as, {:error, :enotsup})
        loop(queue, waiter, eof?)
    end
  end

  defp io_reply(to, reply_as, reply), do: send(to, {:io_reply, reply_as, reply})
end
