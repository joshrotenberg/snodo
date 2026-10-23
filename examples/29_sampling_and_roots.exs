defmodule Examples.SamplingRoots.Server do
  @moduledoc false
  use Snodo.Server, name: "sampling-roots-example", version: "1.0.0"

  # SEP-2577 deprecates the sampling and roots input requests in 2026-07-28;
  # they are still defined, so a handler may ask for them next to
  # elicitation. Prefer elicitation for new designs.
  tool "name_workspace",
    description: "Names the client's workspace with the client's own model" do
    @impl true
    def call(_arguments, context) do
      roots = Snodo.Roots.list()

      naming =
        Snodo.Sampling.create_message(
          [Snodo.Prompt.message(:user, Snodo.Prompt.text("Name this workspace in three words."))],
          max_tokens: 20
        )

      answers = %{
        "roots" => {roots, Snodo.Roots.response(context, "roots", roots)},
        "name" => {naming, Snodo.Sampling.response(context, "name", naming)}
      }

      case Enum.find(answers, fn {_id, {_request, answer}} -> match?({:error, _}, answer) end) do
        {_id, {_request, {:error, error}}} -> {:error, error}
        nil -> finish(answers)
      end
    end

    # Ask again for whatever is still missing; the retry carries the answers
    # given so far, so this tool needs no stored state.
    defp finish(answers) do
      missing = for {id, {request, :missing}} <- answers, into: %{}, do: {id, request}

      if missing == %{} do
        {_roots, {:ok, %{"roots" => roots}}} = answers["roots"]
        {_naming, {:ok, %{"content" => %{"text" => name}}}} = answers["name"]
        # A root is a client claim, not an access grant, and sampled text is
        # untrusted model output: report them, do not act on them.
        {:ok, "#{name} (#{Enum.map_join(roots, ", ", & &1["uri"])})"}
      else
        {:ok, Snodo.Result.input_required(input_requests: missing)}
      end
    end
  end
end

defmodule Examples.SamplingRoots.Runner do
  @moduledoc false

  alias Examples.SamplingRoots.Server
  alias Snodo.Client
  alias Snodo.Error

  def run(args) do
    check? = check_mode!(args)

    # The handlers stand in for the host's model and its workspace. Installing
    # them also declares the sampling and roots client capabilities.
    handlers = %{
      sampling: fn %{"messages" => [_message], "maxTokens" => 20} ->
        {:ok,
         %{
           "role" => "assistant",
           "content" => %{"type" => "text", "text" => "Example docs workspace"},
           "model" => "example-model"
         }}
      end,
      roots: fn _params ->
        {:ok, %{"roots" => [%{"uri" => "file:///tmp/example", "name" => "example"}]}}
      end
    }

    {:ok, client} = Client.direct(Server.runtime(), input_handlers: handlers)

    {:ok, %{"content" => [%{"text" => text}]}} = Client.call_tool(client, "name_workspace")
    ensure(text == "Example docs workspace (file:///tmp/example)", "answered result")

    # A client that declares neither capability is refused before the tool's
    # input requests reach it.
    {:ok, plain} = Client.direct(Server.runtime())
    {:error, %Error{code: -32_021}} = Client.call_tool(plain, "name_workspace")

    if check?, do: IO.puts("29_sampling_and_roots: ok"), else: IO.puts(text)
  end

  defp ensure(true, _label), do: :ok
  defp ensure(false, label), do: raise("check failed: #{label}")

  defp check_mode!([]), do: false
  defp check_mode!(["--check"]), do: true

  defp check_mode!(_arguments),
    do: raise("usage: mix run examples/29_sampling_and_roots.exs [--check]")
end

Examples.SamplingRoots.Runner.run(System.argv())
