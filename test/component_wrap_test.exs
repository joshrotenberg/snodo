defmodule Snodo.ComponentWrapTest do
  use ExUnit.Case, async: false

  alias Snodo.Client
  alias Snodo.Error

  defmodule Refuse do
    @behaviour Snodo.Component.Wrap

    @impl true
    def call(_context, _arguments, _next, options) do
      Snodo.Component.Wrap.reject(options[:kind], "Component refused")
    end
  end

  defmodule DenyInvocation do
    @behaviour Snodo.Authorization

    @impl true
    def authorize(:invocation, _component, _context, _options),
      do: {:error, Error.authorization(-32_003, "Policy refused")}

    def authorize(:discovery, _component, _context, _options), do: :ok
  end

  defmodule Trace do
    @behaviour Snodo.Component.Wrap

    @impl true
    def call(context, arguments, next, options) do
      send(context.auth, {:wrap, options[:label], :before})
      result = next.(context, arguments)
      send(context.auth, {:wrap, options[:label], :after})
      result
    end
  end

  defmodule Tool do
    use Snodo.Tool,
      name: "wrapped_tool",
      wrap: [
        {Snodo.ComponentWrapTest.Trace, label: :outer},
        {Snodo.ComponentWrapTest.Trace, label: :inner}
      ]

    input_schema(%{
      "type" => "object",
      "properties" => %{"name" => %{"type" => "string"}},
      "required" => ["name"]
    })

    @impl true
    def call(%{"name" => name}, context) do
      send(context.auth, {:handler, :tool})
      {:ok, Snodo.Result.text(name)}
    end
  end

  defmodule Resource do
    use Snodo.Resource,
      uri: "test://wrapped/resource",
      name: "wrapped_resource",
      wrap: [{Snodo.ComponentWrapTest.Trace, label: :resource}]

    @impl true
    def read(%{"uri" => uri}, context) do
      send(context.auth, {:handler, :resource})
      {:ok, Snodo.Result.resource_read(Snodo.Resource.text(uri, "resource"))}
    end
  end

  defmodule Prompt do
    use Snodo.Prompt,
      name: "wrapped_prompt",
      arguments: [%{"name" => "query"}],
      completion_arguments: ["query"],
      wrap: [{Snodo.ComponentWrapTest.Trace, label: :prompt}]

    @impl true
    def render(_arguments, context) do
      send(context.auth, {:handler, :prompt})

      {:ok, Snodo.Result.prompt_get(Snodo.Prompt.message(:user, Snodo.Prompt.text("prompt")))}
    end

    @impl true
    def complete(_completion, context) do
      send(context.auth, {:handler, :prompt_completion})
      {:ok, Snodo.Result.completion(["matched"], total: 1)}
    end
  end

  defmodule CompletionResource do
    use Snodo.Resource,
      uri_template: "test://wrapped/items/{name}",
      name: "wrapped_items",
      completion_arguments: ["name"],
      wrap: [{Snodo.ComponentWrapTest.Trace, label: :resource_completion}]

    @impl true
    def read(%{"uri" => uri}, _context),
      do: {:ok, Snodo.Result.resource_read(Snodo.Resource.text(uri, "item"))}

    @impl true
    def complete(_completion, context) do
      send(context.auth, {:handler, :resource_completion})
      {:ok, Snodo.Result.completion(["matched"], total: 1)}
    end
  end

  defmodule RateTool do
    use Snodo.Tool,
      name: "rate_tool",
      wrap: [
        {Snodo.Component.Wrap.RateLimit,
         limit: 2, window_ms: 60_000, key: fn context -> context.auth["principal"] end}
      ]

    @impl true
    def call(_arguments, _context), do: {:ok, Snodo.Result.text("allowed")}
  end

  defmodule AttributeTool do
    @wrappers [{Snodo.ComponentWrapTest.Trace, label: :initial}]
    use Snodo.Tool, name: "attribute_tool", wrap: @wrappers
    @wrappers [Snodo.ComponentWrapTest.Refuse]

    @impl true
    def call(_arguments, _context), do: {:ok, Snodo.Result.text("allowed")}

    def current_wrappers, do: @wrappers
  end

  defmodule ConcurrencyTool do
    use Snodo.Tool,
      name: "concurrency_tool",
      wrap: [{Snodo.Component.Wrap.Concurrency, limit: 1}]

    @impl true
    def call(_arguments, context) do
      send(context.auth, {:entered, self()})

      receive do
        :continue -> {:ok, Snodo.Result.text("done")}
      end
    end
  end

  defmodule TimeoutTool do
    use Snodo.Tool,
      name: "timeout_tool",
      wrap: [{Snodo.Component.Wrap.Timeout, timeout: 40}]

    @impl true
    def call(_arguments, context) do
      send(context.auth, {:entered, self()})

      receive do
        :continue -> {:ok, Snodo.Result.text("unexpected")}
      end
    end
  end

  defmodule LongTimeoutTool do
    use Snodo.Tool,
      name: "long_timeout_tool",
      wrap: [{Snodo.Component.Wrap.Timeout, timeout: 5_000}]

    @impl true
    def call(_arguments, context) do
      send(context.auth, {:entered, self()})

      receive do
        :continue -> {:ok, Snodo.Result.text("unexpected")}
      end
    end
  end

  defmodule RefusedTool do
    use Snodo.Tool,
      name: "refused_tool",
      wrap: [
        Snodo.ComponentWrapTest.Refuse,
        {Snodo.ComponentWrapTest.Trace, label: :after_refuse}
      ]

    @impl true
    def call(_arguments, context) do
      send(context.auth, {:handler, :refused_tool})
      {:ok, Snodo.Result.text("unexpected")}
    end
  end

  defmodule RefusedResource do
    use Snodo.Resource,
      uri: "test://wrapped/refused",
      name: "refused_resource",
      wrap: [Snodo.ComponentWrapTest.Refuse]

    @impl true
    def read(_arguments, _context), do: {:ok, Snodo.Result.resource_read([])}
  end

  defmodule RefusedPrompt do
    use Snodo.Prompt, name: "refused_prompt", wrap: [Snodo.ComponentWrapTest.Refuse]

    @impl true
    def render(_arguments, _context), do: {:ok, Snodo.Result.prompt_get([])}
  end

  defmodule Server do
    use Snodo.Server, name: "component-wrap-test", version: "1.0.0"

    tool(Snodo.ComponentWrapTest.Tool)
    tool(Snodo.ComponentWrapTest.RateTool)
    tool(Snodo.ComponentWrapTest.AttributeTool)
    tool(Snodo.ComponentWrapTest.ConcurrencyTool)
    tool(Snodo.ComponentWrapTest.TimeoutTool)
    tool(Snodo.ComponentWrapTest.LongTimeoutTool)
    tool(Snodo.ComponentWrapTest.RefusedTool)
    resource(Snodo.ComponentWrapTest.Resource)
    resource(Snodo.ComponentWrapTest.CompletionResource)
    resource(Snodo.ComponentWrapTest.RefusedResource)
    prompt(Snodo.ComponentWrapTest.Prompt)
    prompt(Snodo.ComponentWrapTest.RefusedPrompt)

    tool "inline_tool", wrap: [{Snodo.ComponentWrapTest.Trace, label: :inline_tool}] do
      @impl true
      def call(_arguments, context) do
        send(context.auth, {:handler, :inline_tool})
        {:ok, "inline"}
      end
    end

    resource "inline_resource",
      uri: "test://wrapped/inline",
      wrap: [{Snodo.ComponentWrapTest.Trace, label: :inline_resource}] do
      @impl true
      def read(_arguments, context) do
        send(context.auth, {:handler, :inline_resource})
        {:ok, "inline"}
      end
    end

    prompt "inline_prompt", wrap: [{Snodo.ComponentWrapTest.Trace, label: :inline_prompt}] do
      @impl true
      def render(_arguments, context) do
        send(context.auth, {:handler, :inline_prompt})
        {:ok, "inline"}
      end
    end
  end

  defp client(auth), do: elem(Client.direct(Server.runtime(), auth: auth), 1)

  test "wrappers nest in declaration order after input checks" do
    client = client(self())
    assert {:ok, _result} = Client.call_tool(client, "wrapped_tool", %{"name" => "ok"})

    assert Enum.map(1..5, fn _index -> receive_event() end) == [
             {:wrap, :outer, :before},
             {:wrap, :inner, :before},
             {:handler, :tool},
             {:wrap, :inner, :after},
             {:wrap, :outer, :after}
           ]

    assert {:ok, %{"isError" => true}} = Client.call_tool(client, "wrapped_tool", %{})
    refute_received {:wrap, _, :before}
  end

  test "a wrapper may short-circuit and policy refusal runs first" do
    client = client(self())
    assert {:ok, %{"isError" => true}} = Client.call_tool(client, "refused_tool")
    refute_received {:wrap, :after_refuse, :before}
    refute_received {:handler, :refused_tool}

    assert {:error, %Error{code: -32_603}} =
             Client.read_resource(client, "test://wrapped/refused")

    assert {:error, %Error{code: -32_603}} = Client.get_prompt(client, "refused_prompt")

    {:ok, denied} = Client.direct(Server.runtime(authorization: DenyInvocation), auth: self())

    assert {:error, %Error{code: -32_003}} =
             Client.call_tool(denied, "wrapped_tool", %{"name" => "ok"})

    refute_received {:wrap, :outer, :before}
  end

  test "resource and prompt modules and inline components use the same wrapper path" do
    client = client(self())

    assert {:ok, _result} = Client.read_resource(client, "test://wrapped/resource")
    assert_received {:wrap, :resource, :before}
    assert_received {:handler, :resource}
    assert_received {:wrap, :resource, :after}

    assert {:ok, _result} = Client.get_prompt(client, "wrapped_prompt")
    assert_received {:wrap, :prompt, :before}
    assert_received {:handler, :prompt}
    assert_received {:wrap, :prompt, :after}

    assert {:ok, _result} = Client.call_tool(client, "inline_tool")
    assert_received {:wrap, :inline_tool, :before}
    assert_received {:handler, :inline_tool}
    assert_received {:wrap, :inline_tool, :after}

    assert {:ok, _result} = Client.read_resource(client, "test://wrapped/inline")
    assert_received {:wrap, :inline_resource, :before}
    assert_received {:handler, :inline_resource}
    assert_received {:wrap, :inline_resource, :after}

    assert {:ok, _result} = Client.get_prompt(client, "inline_prompt")
    assert_received {:wrap, :inline_prompt, :before}
    assert_received {:handler, :inline_prompt}
    assert_received {:wrap, :inline_prompt, :after}
  end

  test "resource and prompt completions run through their owning wrappers" do
    client = client(self())

    for {reference, label, handler} <- [
          {%{"type" => "ref/prompt", "name" => "wrapped_prompt"}, :prompt, :prompt_completion},
          {%{"type" => "ref/resource", "uri" => "test://wrapped/items/{name}"},
           :resource_completion, :resource_completion}
        ] do
      params = %{
        "ref" => reference,
        "argument" => %{"name" => if(label == :prompt, do: "query", else: "name"), "value" => "m"}
      }

      assert {:ok, %{"completion" => %{"values" => ["matched"]}}} =
               Client.request(client, "completion/complete", params)

      assert_received {:wrap, ^label, :before}
      assert_received {:handler, ^handler}
      assert_received {:wrap, ^label, :after}
    end
  end

  test "rate limits are isolated by a context key" do
    principal = "p-#{System.unique_integer([:positive])}"
    client = client(%{"principal" => principal})

    assert {:ok, _result} = Client.call_tool(client, "rate_tool")
    assert {:ok, _result} = Client.call_tool(client, "rate_tool")
    assert {:ok, %{"isError" => true}} = Client.call_tool(client, "rate_tool")

    other = client(%{"principal" => "#{principal}-other"})
    assert {:ok, _result} = Client.call_tool(other, "rate_tool")
  end

  test "wrapper options are fixed when a component is declared" do
    assert AttributeTool.current_wrappers() == [Refuse]
    assert {:ok, _result} = Client.call_tool(client(self()), "attribute_tool")
    assert_received {:wrap, :initial, :before}
    assert_received {:wrap, :initial, :after}
  end

  test "rate capacity is reclaimed when its window expires" do
    scope = make_ref()
    state = Snodo.Component.Wrap.State

    assert :ok = state.consume(scope, :first, 1, 20, 1)
    assert {:error, :limited} = state.consume(scope, :first, 1, 20, 1)
    assert {:error, :capacity} = state.consume(scope, :second, 1, 20, 1)

    Process.send_after(self(), :window_elapsed, 30)
    assert_receive :window_elapsed, 1_000
    assert :ok = state.consume(scope, :second, 1, 20, 1)
  end

  test "concurrency limit releases its permit when work completes" do
    client = client(self())
    first = Task.async(fn -> Client.call_tool(client, "concurrency_tool") end)
    assert_receive {:entered, pid}, 1_000

    assert {:ok, %{"isError" => true}} = Client.call_tool(client, "concurrency_tool")
    send(pid, :continue)
    assert {:ok, _result} = Task.await(first, 1_000)

    second = Task.async(fn -> Client.call_tool(client, "concurrency_tool") end)
    assert_receive {:entered, second_pid}, 1_000
    send(second_pid, :continue)
    assert {:ok, _result} = Task.await(second, 1_000)
  end

  test "timeout stops the callback and returns a defined tool error" do
    client = client(self())
    assert {:ok, %{"isError" => true}} = Client.call_tool(client, "timeout_tool")
    assert_receive {:entered, pid}, 1_000
    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 1_000
  end

  test "stopping the request owner stops its timeout worker" do
    client = client(self())
    caller = Task.async(fn -> Client.call_tool(client, "long_timeout_tool") end)
    assert_receive {:entered, worker}, 1_000
    worker_monitor = Process.monitor(worker)

    assert nil == Task.shutdown(caller, :brutal_kill)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}, 1_000
  end

  test "invalid wrapper options fail compilation" do
    assert_raise CompileError, ~r/positive :timeout/, fn ->
      Code.compile_string(~S'''
      defmodule Snodo.ComponentWrapTest.InvalidTimeout do
        use Snodo.Tool, name: "invalid_timeout",
          wrap: [{Snodo.Component.Wrap.Timeout, timeout: 0}]

        @impl true
        def call(_, _), do: {:ok, "invalid"}
      end
      ''')
    end
  end

  test "runtime wrapper expressions fail compilation" do
    assert_raise CompileError, ~r/not runtime expressions/, fn ->
      Code.compile_string(~S'''
      defmodule Snodo.ComponentWrapTest.DynamicWrapper do
        use Snodo.Tool, name: "dynamic_wrapper",
          wrap: Application.get_env(:snodo, :wrappers, [])

        @impl true
        def call(_, _), do: {:ok, "invalid"}
      end
      ''')
    end

    assert_raise CompileError, ~r/not runtime expressions/, fn ->
      Code.compile_string(~S'''
      defmodule Snodo.ComponentWrapTest.DynamicOption do
        use Snodo.Tool, name: "dynamic_option",
          wrap: [{Snodo.Component.Wrap.Timeout,
            timeout: Application.get_env(:snodo, :timeout, 100)}]

        @impl true
        def call(_, _), do: {:ok, "invalid"}
      end
      ''')
    end
  end

  defp receive_event do
    receive do
      {:wrap, _label, _stage} = event -> event
      {:handler, _kind} = event -> event
    after
      1_000 -> flunk("wrapper event did not arrive")
    end
  end
end
