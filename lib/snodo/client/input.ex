defmodule Snodo.Client.Input do
  @moduledoc false
  # Answers the input requests of an `input_required` result with the
  # handlers installed on a `Snodo.Client`.
  #
  # `@kinds` is the registry. Each kind names the embedded request method it
  # answers, the elicitation `mode` when the method has one, the `params`
  # keys a request of that kind must carry (`params: :optional` for a method
  # whose schema lets the object out), and the client capabilities that
  # advertise it. A new kind is one more entry here, one more
  # `valid_response?/2` clause, and one more member of
  # `Snodo.Client.input_kind/0`; the loop in `Snodo.Client` does not change,
  # and neither does `answer_request/2`, which answers the same methods when
  # an initialize-era server sends them as top-level requests.

  alias Snodo.Client.Transport
  alias Snodo.Error
  alias Snodo.Roots
  alias Snodo.Sampling

  @kinds %{
    form: %{
      method: "elicitation/create",
      mode: "form",
      required: ~w(message requestedSchema),
      capability: %{"elicitation" => %{"form" => %{}}}
    },
    url: %{
      method: "elicitation/create",
      mode: "url",
      required: ~w(message url),
      capability: %{"elicitation" => %{"url" => %{}}}
    },
    # SEP-2577 deprecates the two embedded requests below; the protocol still
    # defines them. The declared roots capability says nothing changes, since
    # the client sends no notifications.
    sampling: %{
      method: "sampling/createMessage",
      mode: nil,
      required: ~w(messages maxTokens),
      capability: %{"sampling" => %{}}
    },
    roots: %{
      method: "roots/list",
      mode: nil,
      required: [],
      params: :optional,
      capability: %{"roots" => %{"listChanged" => false}}
    }
  }

  @elicitation_actions ~w(accept decline cancel)

  @doc false
  @spec validate_handlers!(term()) :: Snodo.Client.input_handlers()
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
  @spec capabilities(Snodo.Client.input_handlers()) :: map()
  def capabilities(handlers) do
    Enum.reduce(handlers, %{}, fn {kind, _fun}, capabilities ->
      merge(capabilities, @kinds[kind].capability)
    end)
  end

  @doc false
  @spec merge_capabilities(map(), map()) :: map()
  def merge_capabilities(derived, declared) do
    declared = if is_map_key(derived, "elicitation"), do: normalize(declared), else: declared
    merge(derived, declared)
  end

  # The declared value wins at a leaf such as roots.listChanged; an entry a
  # handler needs to merge into must stay a map.
  defp merge(derived, declared) do
    Map.merge(derived, declared, fn
      _key, from_handlers, given when is_map(from_handlers) and is_map(given) ->
        merge(from_handlers, given)

      _key, from_handlers, given when not is_map(from_handlers) ->
        given

      key, _from_handlers, given ->
        raise ArgumentError,
              ":client_capabilities declares #{inspect(key)} as #{inspect(given)}, " <>
                "which the :input_handlers need to be a map"
    end)
  end

  @doc """
  Answers every input request of an `input_required` result.

  Every request is matched to a handler first; a request with no handler, or
  one the server sent malformed, fails the round before any handler runs.
  The handlers then run in the calling process, one request at a time in the
  sort order of the request IDs (strings, so `"10"` comes before `"2"`). A
  result with a `requestState` and no input requests has nothing to answer
  and returns `{:ok, %{}}`.
  """
  @spec answer(Snodo.Client.input_handlers(), map()) :: {:ok, map()} | {:error, Error.t()}
  def answer(handlers, result) do
    requests = Map.get(result, "inputRequests", %{})

    cond do
      not is_map(requests) ->
        {:error,
         malformed(
           "The server sent an input_required result whose inputRequests is not an object",
           result
         )}

      map_size(requests) == 0 and not Map.has_key?(result, "requestState") ->
        {:error,
         malformed(
           "The server sent an input_required result with nothing to answer and no request state",
           result
         )}

      true ->
        with {:ok, resolved} <- resolve_all(handlers, requests, result) do
          run_all(resolved, result)
        end
    end
  end

  @doc false
  # Answers one request the server sent to the client on an initialize-era
  # connection, through the same registry as an embedded input request. The
  # result is the JSON-RPC response object to send back: -32601 for a method
  # or mode with no handler, -32602 for params that lack the kind's keys, and
  # -32603 for a handler that failed. `ping` needs no handler. An exception
  # raised by a handler propagates, as it does for an embedded request.
  @spec answer_request(Snodo.Client.input_handlers(), map()) :: map()
  def answer_request(_handlers, %{"id" => id, "method" => "ping"}), do: response(id, %{})

  def answer_request(handlers, %{"id" => id, "method" => method} = request)
      when is_binary(method) do
    with {:ok, kind} <- classify_kind(request),
         {:ok, params} <- request_params(kind, request),
         {:ok, fun} <- Map.fetch(handlers, kind),
         {:ok, response} <- run_request(fun, kind, params) do
      response(id, response)
    else
      :error -> error_response(id, Error.method_not_found(method))
      {:error, %Error{} = error} -> error_response(id, error)
    end
  end

  defp request_params(kind, request) do
    params = Map.get(request, "params", absent_params(@kinds[kind]))

    case check_params(kind, params) do
      :ok ->
        {:ok, params}

      {:error, :not_an_object} ->
        {:error, Error.invalid_params("params must be an object")}

      {:error, {:missing, keys}} ->
        {:error, Error.invalid_params("A #{describe(kind)} needs #{inspect(keys)} in its params")}
    end
  end

  defp run_request(fun, kind, params) do
    case fun.(params) do
      {:ok, response} ->
        if valid_response?(kind, response),
          do: {:ok, response},
          else: {:error, Error.internal("Input handler returned an invalid response")}

      {:error, reason} ->
        {:error, Error.internal("Input handler failed", reason)}

      _other ->
        {:error, Error.internal("Input handler returned an invalid value")}
    end
  end

  defp response(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp error_response(id, %Error{} = error),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => Error.to_json_rpc(error)}

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

  # Pass one: every request gets a kind, a handler, and checked params, or
  # the round fails with nothing run.
  defp resolve_all(handlers, requests, result) do
    requests
    |> Enum.sort_by(fn {id, _request} -> id end)
    |> Enum.reduce_while({:ok, []}, fn {id, request}, {:ok, resolved} ->
      case resolve(handlers, id, request, result) do
        {:ok, entry} -> {:cont, {:ok, [entry | resolved]}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, resolved} -> {:ok, Enum.reverse(resolved)}
      error -> error
    end
  end

  # Pass two: the handlers run in ID order; the first failure stops the round.
  defp run_all(resolved, result) do
    Enum.reduce_while(resolved, {:ok, %{}}, fn {id, kind, fun, params}, {:ok, responses} ->
      case run(fun, id, kind, params, result) do
        {:ok, response} -> {:cont, {:ok, Map.put(responses, id, response)}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp resolve(handlers, id, request, result) when is_map(request) do
    with {:ok, kind} <- classify(id, request, result),
         {:ok, params} <- checked_params(id, kind, request, result),
         {:ok, fun} <- fetch_handler(handlers, id, kind, result) do
      {:ok, {id, kind, fun, params}}
    end
  end

  defp resolve(_handlers, id, _request, result) do
    {:error,
     malformed("The server sent input request #{inspect(id)} that is not an object", result)}
  end

  # Only the elicitation kinds carry a mode; the other specs leave it nil and
  # match on the method alone, so a stray "mode" in their params is ignored.
  defp classify(id, %{"method" => method} = request, result) when is_binary(method) do
    case classify_kind(request) do
      {:ok, kind} -> {:ok, kind}
      :error -> {:error, no_handler(id, method, result)}
    end
  end

  defp classify(id, _request, result), do: {:error, no_handler(id, nil, result)}

  defp classify_kind(%{"method" => method} = request) do
    mode = request |> Map.get("params") |> mode()

    case Enum.find(@kinds, fn {_kind, spec} ->
           spec.method == method and spec.mode in [nil, mode]
         end) do
      {kind, _spec} -> {:ok, kind}
      nil -> :error
    end
  end

  defp mode(%{"mode" => mode}), do: mode
  defp mode(_params), do: "form"

  # The handler is promised a map with the keys its kind documents; a request
  # that lacks them is the server's fault, not the handler's.
  defp checked_params(id, kind, request, result) do
    params = Map.get(request, "params", absent_params(@kinds[kind]))

    case check_params(kind, params) do
      :ok ->
        {:ok, params}

      {:error, :not_an_object} ->
        {:error,
         malformed(
           "The server sent input request #{inspect(id)} whose params is not an object",
           result
         )}

      {:error, {:missing, keys}} ->
        {:error,
         malformed(
           "The server sent input request #{inspect(id)}, a #{describe(kind)}, " <>
             "without #{inspect(keys)} in its params",
           result
         )}
    end
  end

  defp check_params(_kind, params) when not is_map(params), do: {:error, :not_an_object}

  defp check_params(kind, params) do
    case Enum.reject(@kinds[kind].required, &is_map_key(params, &1)) do
      [] -> :ok
      _missing -> {:error, {:missing, @kinds[kind].required}}
    end
  end

  # A roots/list request may leave params out; its handler still gets a map.
  defp absent_params(%{params: :optional}), do: %{}
  defp absent_params(_spec), do: nil

  defp fetch_handler(handlers, id, kind, result) do
    case Map.fetch(handlers, kind) do
      {:ok, fun} -> {:ok, fun}
      :error -> {:error, no_handler(id, kind, result)}
    end
  end

  defp run(fun, id, kind, params, result) do
    case fun.(params) do
      {:ok, response} ->
        if valid_response?(kind, response),
          do: {:ok, response},
          else: {:error, handler_failed(id, {:invalid_response, response}, result)}

      {:error, reason} ->
        {:error, handler_failed(id, reason, result)}

      other ->
        {:error, handler_failed(id, {:invalid_return, other}, result)}
    end
  end

  defp valid_response?(kind, %{"action" => action} = response)
       when kind in [:form, :url] and action in @elicitation_actions do
    not is_struct(response) and Enum.all?(Map.keys(response), &is_binary/1)
  end

  defp valid_response?(:sampling, response), do: Sampling.valid_response?(response)
  defp valid_response?(:roots, response), do: Roots.valid_response?(response)
  defp valid_response?(_kind, _response), do: false

  defp no_handler(id, nil, result) do
    %{
      Error.invalid_params("Input request #{inspect(id)} has no method", %{"inputRequest" => id})
      | cause: {:no_input_handler, nil, result}
    }
  end

  defp no_handler(id, kind, result) do
    %{
      Error.invalid_params(
        "No input handler for #{describe(kind)} (input request #{inspect(id)})",
        %{"inputRequest" => id}
      )
      | cause: {:no_input_handler, kind, result}
    }
  end

  defp describe(:form), do: "form elicitation"
  defp describe(:url), do: "URL elicitation"
  defp describe(:sampling), do: "sampling request"
  defp describe(:roots), do: "roots request"
  defp describe(method) when is_binary(method), do: "#{method} requests"

  defp handler_failed(id, reason, result) do
    %Error{
      code: -32_603,
      message: "Input handler failed for input request #{inspect(id)}",
      kind: :execution,
      cause: {:input_handler, id, reason, result}
    }
  end

  defp malformed(message, result), do: Transport.connection_error(message, result)

  # An empty elicitation capability means form mode alone. Spelling that out
  # keeps form when a URL handler adds its own entry next to it. Only a
  # handler's entry triggers it, so a client without handlers declares the
  # bytes it was given.
  defp normalize(%{"elicitation" => elicitation} = declared)
       when is_map(elicitation) and map_size(elicitation) == 0 do
    Map.put(declared, "elicitation", %{"form" => %{}})
  end

  defp normalize(declared), do: declared
end
