defmodule SnodoTest.TestExtensions.DefaultCallbacks do
  @moduledoc false

  alias Snodo.Error
  alias Snodo.Result

  def negotiate(client_settings, server_settings) do
    {:ok, %{"client" => client_settings, "server" => server_settings}}
  end

  def validate_operation(_operation, _params, _context), do: :ok

  def dispatch(operation, params, _context) do
    {:ok, Result.structured(%{"operation" => inspect(operation), "params" => params})}
  end

  def shape_result(_operation, %Result{} = result, _context), do: %{"value" => result.value}
  def shape_error(%Error{} = error, _context), do: Error.to_json_rpc(error)
end

defmodule SnodoTest.TestExtensions.Definition do
  @moduledoc false

  defmacro __using__(opts) do
    id = Keyword.fetch!(opts, :id)
    name = Keyword.fetch!(opts, :name)
    version = Keyword.get(opts, :version, "2026-07-28")
    operation = Keyword.get(opts, :operation, :test_extension_operation)

    quote do
      @behaviour Snodo.Extension

      alias Snodo.Extension.Method
      alias SnodoTest.TestExtensions.DefaultCallbacks

      @extension_id unquote(id)
      @extension_method unquote(name)
      @extension_version unquote(version)
      @extension_operation unquote(Macro.escape(operation))

      @impl true
      def id, do: @extension_id

      @impl true
      def methods do
        [
          Method.new!(
            protocol_version: @extension_version,
            name: @extension_method,
            operation: @extension_operation
          )
        ]
      end

      @impl true
      defdelegate negotiate(client_settings, server_settings), to: DefaultCallbacks

      @impl true
      defdelegate validate_operation(operation, params, context), to: DefaultCallbacks

      @impl true
      defdelegate dispatch(operation, params, context), to: DefaultCallbacks

      @impl true
      defdelegate shape_result(operation, result, context), to: DefaultCallbacks

      @impl true
      defdelegate shape_error(error, context), to: DefaultCallbacks

      defoverridable negotiate: 2,
                     validate_operation: 3,
                     dispatch: 3,
                     shape_result: 3,
                     shape_error: 2
    end
  end
end

defmodule SnodoTest.TestExtensions.Echo do
  @moduledoc false
  @behaviour Snodo.Extension

  alias Snodo.Error
  alias Snodo.Extension.Method
  alias Snodo.Result

  @id "com.example/echo"

  @impl true
  def id, do: @id

  @impl true
  def methods do
    [
      Method.new!(
        protocol_version: "2026-07-28",
        name: "com.example/echo",
        operation: :echo
      )
    ]
  end

  @impl true
  def negotiate(client_settings, server_settings) do
    {:ok,
     %{
       "clientMode" => Map.get(client_settings, "mode"),
       "serverMode" => Map.get(server_settings, "mode")
     }}
  end

  @impl true
  def validate_operation(:echo, %{"value" => value}, _context) when is_binary(value), do: :ok

  def validate_operation(:echo, _params, _context) do
    {:error,
     Error.invalid_params("Extension value must be a string", %{
       "extension" => @id,
       "field" => "value"
     })}
  end

  @impl true
  def dispatch(:echo, %{"value" => "dispatch-error"}, _context) do
    {:error, Error.internal("Extension dispatch failed", :private_dispatch_cause)}
  end

  def dispatch(:echo, %{"value" => value}, context) do
    {:ok,
     Result.structured(%{
       "value" => value,
       "negotiated" => Map.fetch!(context.extensions, @id)
     })}
  end

  @impl true
  def shape_result(:echo, %Result{} = result, context) do
    %{
      "extensionResult" => result.value,
      "contextExtensions" => context.extensions
    }
  end

  @impl true
  def shape_error(%Error{} = error, context) do
    %{
      "code" => error.code,
      "message" => "Echo extension rejected the request",
      "data" => %{
        "negotiated" => Map.get(context.extensions, @id),
        "originalData" => error.data
      }
    }
  end
end

defmodule SnodoTest.TestExtensions.NotNegotiated do
  @moduledoc false
  use SnodoTest.TestExtensions.Definition,
    id: "com.example/not-negotiated",
    name: "com.example/not-negotiated"

  @impl true
  def negotiate(_client_settings, _server_settings), do: :not_negotiated
end

defmodule SnodoTest.TestExtensions.AroundCallbacks do
  @moduledoc false

  alias Snodo.Context

  def call(id, _operation, _params, %Context{} = context, next) do
    options = Map.fetch!(context.extension_options, id)
    owner = fetch_option!(options, :owner)
    label = fetch_option!(options, :label)
    trace = Map.get(context.metadata, "middlewareTrace", [])

    send(
      owner,
      {:around_dispatch, label, :before, negotiated?(context, id), options,
       context.extension_options, trace}
    )

    next_context = %{
      context
      | metadata: Map.put(context.metadata, "middlewareTrace", trace ++ [label])
    }

    result = next.(next_context)
    send(owner, {:around_dispatch, label, :after, negotiated?(context, id), options})
    result
  end

  def fetch_option!(options, key) when is_list(options), do: Keyword.fetch!(options, key)
  def fetch_option!(options, key) when is_map(options), do: Map.fetch!(options, key)

  defp negotiated?(context, id), do: Map.has_key?(context.extensions, id)
end

defmodule SnodoTest.TestExtensions.AroundOuter do
  @moduledoc false
  use SnodoTest.TestExtensions.Definition,
    id: "com.example/around-outer",
    name: "com.example/around-outer"

  alias SnodoTest.TestExtensions.AroundCallbacks

  @impl true
  def around_dispatch(operation, params, context, next) do
    AroundCallbacks.call(id(), operation, params, context, next)
  end
end

defmodule SnodoTest.TestExtensions.AroundInner do
  @moduledoc false
  use SnodoTest.TestExtensions.Definition,
    id: "com.example/around-inner",
    name: "com.example/around-inner"

  alias SnodoTest.TestExtensions.AroundCallbacks

  @impl true
  def around_dispatch(operation, params, context, next) do
    AroundCallbacks.call(id(), operation, params, context, next)
  end
end

defmodule SnodoTest.TestExtensions.FutureAround do
  @moduledoc false
  use SnodoTest.TestExtensions.Definition,
    id: "com.example/future-around",
    name: "com.example/future-around",
    version: "2099-01-01"

  alias SnodoTest.TestExtensions.AroundCallbacks

  @impl true
  def around_dispatch(operation, params, context, next) do
    AroundCallbacks.call(id(), operation, params, context, next)
  end
end

defmodule SnodoTest.TestExtensions.FaultyAround do
  @moduledoc false
  use SnodoTest.TestExtensions.Definition,
    id: "com.example/faulty-around",
    name: "com.example/faulty-around"

  alias Snodo.Result
  alias SnodoTest.TestExtensions.AroundCallbacks

  @impl true
  def around_dispatch(_operation, _params, context, next) do
    options = Map.fetch!(context.extension_options, id())

    case AroundCallbacks.fetch_option!(options, :mode) do
      :raise -> raise "private around_dispatch implementation detail"
      :invalid -> {:ok, :private_invalid_result}
      :short_circuit -> {:ok, Result.text("short-circuited")}
      :continue -> next.(context)
    end
  end
end

defmodule SnodoTest.TestExtensions.RequiredCapability do
  @moduledoc false
  use SnodoTest.TestExtensions.Definition,
    id: "com.example/required-capability",
    name: "com.example/required-capability"

  alias Snodo.Error
  alias SnodoTest.TestExtensions.AroundCallbacks

  @impl true
  def missing_capability_error(_method, context) do
    options = Map.fetch!(context.extension_options, id())

    case AroundCallbacks.fetch_option!(options, :mode) do
      :required ->
        %Error{
          code: -32_021,
          message: "Missing required client capability",
          kind: :extension,
          data: %{
            "requiredCapabilities" => %{
              "extensions" => %{id() => %{}}
            }
          }
        }

      :method_not_found ->
        :method_not_found

      :raise ->
        raise "private missing-capability implementation detail"

      :invalid ->
        :private_invalid_result
    end
  end
end

defmodule SnodoTest.TestExtensions.HTTPPolicy do
  @moduledoc false
  use SnodoTest.TestExtensions.Definition,
    id: "com.example/http-policy",
    name: "com.example/http-policy"

  alias Snodo.Envelope
  alias Snodo.Transport.Policy

  @impl true
  def transport_policy(%Envelope{params: %{"policyMode" => "raise"}}, %Policy{}) do
    raise "private transport-policy implementation detail"
  end

  def transport_policy(%Envelope{params: %{"policyMode" => "invalid"}}, %Policy{}) do
    :private_invalid_policy
  end

  def transport_policy(%Envelope{}, %Policy{} = base_policy) do
    %{
      base_policy
      | required_headers: Enum.uniq(base_policy.required_headers ++ ["mcp-name"]),
        mirrored_headers:
          Map.put(base_policy.mirrored_headers, "mcp-name", %{path: ["params", "taskId"]})
    }
  end
end

defmodule SnodoTest.TestExtensions.Faulty do
  @moduledoc false
  @behaviour Snodo.Extension

  alias Snodo.Error
  alias Snodo.Extension.Method
  alias Snodo.Result

  @id "com.example/faulty"

  @impl true
  def id, do: @id

  @impl true
  def methods do
    [
      Method.new!(
        protocol_version: "2026-07-28",
        name: "com.example/faulty",
        operation: :faulty
      )
    ]
  end

  @impl true
  def negotiate(client_settings, server_settings) do
    {:ok, %{"client" => client_settings, "server" => server_settings}}
  end

  @impl true
  def validate_operation(:faulty, %{"stage" => "validate"}, _context) do
    raise "private validator implementation detail"
  end

  def validate_operation(:faulty, _params, _context), do: :ok

  @impl true
  def dispatch(:faulty, %{"stage" => "dispatch"}, _context) do
    raise "private dispatcher implementation detail"
  end

  def dispatch(:faulty, %{"stage" => "shape_error"}, _context) do
    {:error,
     Error.invalid_params("Trigger error shaper", %{
       "stage" => "shape_error",
       "private" => "private error implementation detail"
     })}
  end

  def dispatch(:faulty, %{"stage" => stage}, _context) do
    {:ok, Result.structured(%{"stage" => stage})}
  end

  @impl true
  def shape_result(:faulty, %Result{value: %{"stage" => "shape_result"}}, _context) do
    raise "private result shaper implementation detail"
  end

  def shape_result(:faulty, %Result{} = result, _context), do: %{"value" => result.value}

  @impl true
  def shape_error(%Error{data: %{"stage" => "shape_error"}}, _context) do
    raise "private error shaper implementation detail"
  end

  def shape_error(%Error{} = error, _context) do
    %{"code" => error.code, "message" => "Faulty extension callback failed safely"}
  end
end

defmodule SnodoTest.TestExtensions.CoreImplementedCollision do
  @moduledoc false
  use SnodoTest.TestExtensions.Definition,
    id: "com.example/core-implemented",
    name: "tools/list"
end

defmodule SnodoTest.TestExtensions.CoreUnsupportedCollision do
  @moduledoc false
  use SnodoTest.TestExtensions.Definition,
    id: "com.example/core-unsupported",
    name: "resources/list"
end

defmodule SnodoTest.TestExtensions.CoreEmbeddedCollision do
  @moduledoc false
  use SnodoTest.TestExtensions.Definition,
    id: "com.example/core-embedded",
    name: "elicitation/create"
end

defmodule SnodoTest.TestExtensions.CrossCollisionA do
  @moduledoc false
  use SnodoTest.TestExtensions.Definition,
    id: "com.example/cross-a",
    name: "com.example/shared"
end

defmodule SnodoTest.TestExtensions.CrossCollisionB do
  @moduledoc false
  use SnodoTest.TestExtensions.Definition,
    id: "com.example/cross-b",
    name: "com.example/shared"
end

defmodule SnodoTest.TestExtensions.DuplicateId do
  @moduledoc false
  use SnodoTest.TestExtensions.Definition,
    id: "com.example/echo",
    name: "com.example/duplicate-id"
end

defmodule SnodoTest.TestExtensions.UnavailableVersion do
  @moduledoc false
  use SnodoTest.TestExtensions.Definition,
    id: "com.example/future",
    name: "com.example/future",
    version: "2099-12-31"
end

defmodule SnodoTest.TestExtensions.IncompleteSubscriptions do
  @moduledoc false
  use SnodoTest.TestExtensions.Definition,
    id: "com.example/incomplete-subscriptions",
    name: "com.example/incomplete-subscriptions"

  @impl true
  def subscription_filter(_requested_filter, _context), do: {:ok, %{}}
end

defmodule SnodoTest.ExtensionTestServer do
  @moduledoc false

  use Snodo.Server,
    name: "extension-dsl-server",
    version: "0.1.0",
    extensions: [SnodoTest.TestExtensions.Echo],
    capabilities: %{
      "extensions" => %{"com.example/echo" => %{"mode" => "server"}}
    }
end
