defmodule Snodo.Client.Input do
  @moduledoc false
  # Answers the input requests of an `input_required` result with the
  # handlers installed on a `Snodo.Client`.
  #
  # `@kinds` is the registry. Each kind names the embedded request method it
  # answers, the elicitation `mode` when the method has one, and the client
  # capability path that advertises it. A new kind is one more entry here and
  # one more `valid_response?/2` clause; the loop in `Snodo.Client` does not
  # change.

  alias Snodo.Client.Transport
  alias Snodo.Error

  @type kind :: :form | :url
  @type handler :: (map() -> {:ok, map()} | {:error, term()})
  @type handlers :: %{optional(kind()) => handler()}

  @kinds %{
    form: %{method: "elicitation/create", mode: "form", capability: ["elicitation", "form"]},
    url: %{method: "elicitation/create", mode: "url", capability: ["elicitation", "url"]}
  }

  @elicitation_actions ~w(accept decline cancel)

  @doc false
  @spec validate_handlers!(term()) :: handlers()
  def validate_handlers!(handlers) when is_map(handlers) and not is_struct(handlers) do
    Enum.each(handlers, fn
      {kind, fun} when is_map_key(@kinds, kind) and is_function(fun, 1) ->
        :ok

      {kind, fun} when is_map_key(@kinds, kind) ->
        raise ArgumentError,
              ":input_handlers #{inspect(kind)} must be a function of one argument, " <>
                "got: #{inspect(fun)}"

      {kind, _fun} ->
        raise ArgumentError,
              "unknown input handler kind #{inspect(kind)}; " <>
                "the kinds are #{inspect(Map.keys(@kinds))}"
    end)

    handlers
  end

  def validate_handlers!(other) do
    raise ArgumentError,
          ":input_handlers must be a map from kind to function, got: #{inspect(other)}"
  end

  @doc false
  @spec capabilities(handlers()) :: map()
  def capabilities(handlers) do
    Enum.reduce(handlers, %{}, fn {kind, _fun}, capabilities ->
      put_path(capabilities, @kinds[kind].capability)
    end)
  end

  @doc false
  @spec merge_capabilities(map(), map()) :: map()
  def merge_capabilities(derived, declared) do
    Map.merge(derived, normalize(declared), fn _key, from_handlers, given ->
      if is_map(from_handlers) and is_map(given),
        do: merge_capabilities(from_handlers, given),
        else: given
    end)
  end

  @doc """
  Answers every input request of an `input_required` result.

  Handlers run in the calling process, one request at a time in ID order. A
  result with a `requestState` and no input requests has nothing to answer
  and returns `{:ok, %{}}`.
  """
  @spec answer(handlers(), map()) :: {:ok, map()} | {:error, Error.t()}
  def answer(handlers, result) do
    requests = Map.get(result, "inputRequests", %{})

    cond do
      not is_map(requests) ->
        {:error,
         Transport.connection_error(
           "The server sent an input_required result whose inputRequests is not an object",
           result
         )}

      map_size(requests) == 0 and not Map.has_key?(result, "requestState") ->
        {:error,
         Transport.connection_error(
           "The server sent an input_required result with nothing to answer and no request state",
           result
         )}

      true ->
        answer_all(handlers, requests)
    end
  end

  @doc false
  @spec rounds_exceeded(pos_integer(), map()) :: Error.t()
  def rounds_exceeded(limit, result) do
    error =
      Transport.connection_error(
        "The server still required input after #{limit} rounds",
        {:max_input_rounds, result}
      )

    %{error | data: %{"maxInputRounds" => limit}}
  end

  defp answer_all(handlers, requests) do
    requests
    |> Enum.sort_by(fn {id, _request} -> id end)
    |> Enum.reduce_while({:ok, %{}}, fn {id, request}, {:ok, responses} ->
      case answer_one(handlers, id, request) do
        {:ok, response} -> {:cont, {:ok, Map.put(responses, id, response)}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp answer_one(handlers, id, request) do
    with {:ok, kind} <- classify(id, request),
         {:ok, fun} <- fetch_handler(handlers, id, kind),
         {:ok, response} <- run(fun, id, Map.get(request, "params", %{})) do
      if valid_response?(kind, response),
        do: {:ok, response},
        else: {:error, handler_failed(id, {:invalid_response, response})}
    end
  end

  defp classify(id, %{"method" => method} = request) when is_binary(method) do
    mode = request |> Map.get("params") |> mode()

    case Enum.find(@kinds, fn {_kind, spec} ->
           spec.method == method and spec.mode in [nil, mode]
         end) do
      {kind, _spec} -> {:ok, kind}
      nil -> {:error, no_handler(id, method)}
    end
  end

  defp classify(id, _request), do: {:error, no_handler(id, nil)}

  defp mode(%{"mode" => mode}), do: mode
  defp mode(_params), do: "form"

  defp fetch_handler(handlers, id, kind) do
    case Map.fetch(handlers, kind) do
      {:ok, fun} -> {:ok, fun}
      :error -> {:error, no_handler(id, kind)}
    end
  end

  defp run(fun, id, params) do
    case fun.(params) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, handler_failed(id, reason)}
      other -> {:error, handler_failed(id, {:invalid_return, other})}
    end
  end

  defp valid_response?(kind, %{"action" => action} = response)
       when kind in [:form, :url] and action in @elicitation_actions do
    not is_struct(response) and Enum.all?(Map.keys(response), &is_binary/1)
  end

  defp valid_response?(_kind, _response), do: false

  defp no_handler(id, nil) do
    %{
      Error.invalid_params("Input request #{inspect(id)} has no method", %{"inputRequest" => id})
      | cause: {:no_input_handler, nil}
    }
  end

  defp no_handler(id, kind) do
    %{
      Error.invalid_params(
        "No input handler for #{describe(kind)} (input request #{inspect(id)})",
        %{"inputRequest" => id}
      )
      | cause: {:no_input_handler, kind}
    }
  end

  defp describe(:form), do: "form elicitation"
  defp describe(:url), do: "URL elicitation"
  defp describe(method) when is_binary(method), do: "#{method} requests"

  defp handler_failed(id, reason) do
    %Error{
      code: -32_603,
      message: "Input handler failed for input request #{inspect(id)}",
      kind: :execution,
      cause: {:input_handler, id, reason}
    }
  end

  defp put_path(map, [key]), do: Map.put_new(map, key, %{})

  defp put_path(map, [key | rest]) do
    Map.put(map, key, put_path(Map.get(map, key, %{}), rest))
  end

  # An empty elicitation capability means form mode alone. Spelling that out
  # keeps form when a URL handler adds its own entry next to it.
  defp normalize(%{"elicitation" => elicitation} = declared)
       when is_map(elicitation) and map_size(elicitation) == 0 do
    Map.put(declared, "elicitation", %{"form" => %{}})
  end

  defp normalize(declared), do: declared
end
