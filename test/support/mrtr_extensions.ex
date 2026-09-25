defmodule SnodoTest.MRTR.AroundExtension do
  @moduledoc false
  use SnodoTest.TestExtensions.Definition,
    id: "com.example/mrtr-around",
    name: "com.example/mrtr-around"

  alias Snodo.Error
  alias Snodo.Result
  alias SnodoTest.MRTR.Choice

  @impl true
  def around_dispatch(operation, params, context, next) do
    options = Map.fetch!(context.extension_options, id())
    owner = Keyword.fetch!(options, :owner)
    mode = Keyword.fetch!(options, :mode)
    send(owner, {:mrtr_around, context.request_id, operation, params, context})

    next_context = %{
      context
      | metadata: Map.put(context.metadata, "mrtrMark", "seen-#{context.request_id}")
    }

    result = run(mode, next_context, next)
    send(owner, {:mrtr_around_returned, context.request_id, result})
    result
  end

  defp run(:observe, context, next), do: next.(context)

  defp run(:guard, _context, _next) do
    {:error, Error.invalid_params("MRTR extension guard rejected the retry", %{"guard" => true})}
  end

  defp run(mode, context, next) when mode in [:forge, :forge_wire] do
    forged = %{context | client_capabilities: %{"elicitation" => %{"form" => %{}}}}

    case next.(forged) do
      {:ok, %Result{kind: :input_required} = result} when mode == :forge_wire ->
        {:ok, as_wire(result)}

      result ->
        result
    end
  end

  defp run(:replace, _context, _next), do: {:ok, input_required()}
  defp run(:replace_wire, _context, _next), do: {:ok, as_wire(input_required())}

  defp run(:custom_input, _context, _next) do
    {:ok,
     Result.input_required(input_requests: %{"custom" => %{"method" => id(), "params" => %{}}})}
  end

  defp input_required do
    Result.input_required(input_requests: %{"choice" => Choice.request()})
  end

  defp as_wire(result), do: Result.wire(Map.put(result.value, "resultType", "input_required"))
end

defmodule SnodoTest.MRTR.ObservedTool do
  @moduledoc false
  use Snodo.Tool, name: "observed_choice"

  alias Snodo.Result
  alias SnodoTest.MRTR.AroundExtension
  alias SnodoTest.MRTR.Choice

  @impl true
  def call(arguments, context) do
    owner =
      context.extension_options |> Map.fetch!(AroundExtension.id()) |> Keyword.fetch!(:owner)

    send(owner, {:mrtr_tool, context.request_id, arguments, context})

    Choice.run(context, fn label ->
      Result.structured(%{"label" => label, "middlewareMark" => context.metadata["mrtrMark"]})
    end)
  end
end
