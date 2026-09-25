defmodule Snodo.MRTR do
  @moduledoc """
  Validation for the ordinary multi round-trip request boundary.

  Tools, resources, and prompts may return `Snodo.Result.input_required/1`.
  A retry invokes the component again with the original component arguments
  and a fresh `Snodo.Context`; no process or implicit continuation is retained.
  Components should consume only the input IDs they need, re-request missing
  answers, and perform effects only after validating input and any state.

  This slice implements elicitation and state-only continuations. Deprecated
  roots and sampling input requests remain unsupported. Extensions retain
  their own negotiated routes and wire results; ordinary core results still
  pass the selected dialect's admission after extension middleware completes.
  """

  alias Snodo.Context
  alias Snodo.Elicitation
  alias Snodo.Error
  alias Snodo.JSONValue
  alias Snodo.Result

  @operations [:tools_call, :resource_read, :prompt_get]

  @doc false
  @spec inspect_params(map()) :: :ok | {:error, String.t()}
  def inspect_params(params) do
    with :ok <- optional_state(params) do
      case Map.fetch(params, "inputResponses") do
        :error -> :ok
        {:ok, responses} -> inspect_responses(responses)
      end
    end
  end

  defp optional_state(params) do
    case Map.fetch(params, "requestState") do
      :error -> :ok
      {:ok, state} when is_binary(state) -> :ok
      {:ok, _invalid} -> {:error, "requestState must be a string"}
    end
  end

  defp inspect_responses(responses) when is_map(responses) and not is_struct(responses) do
    if JSONValue.valid?(responses) and
         Enum.all?(responses, fn {_id, value} -> is_map(value) end),
       do: :ok,
       else: {:error, "inputResponses must map string IDs to bare result objects"}
  end

  defp inspect_responses(_invalid),
    do: {:error, "inputResponses must be an object"}

  @doc false
  @spec validate_result(term(), Result.t(), Context.t()) :: :ok | {:error, Error.t()}
  def validate_result(operation, %Result{kind: :input_required, value: value}, context) do
    validate_input_required(operation, value, context)
  end

  # The wire escape hatch is not a way to bypass core MRTR placement or peer
  # capabilities. Other extension-defined variants retain their own semantics.
  def validate_result(
        operation,
        %Result{kind: :wire, value: %{"resultType" => "input_required"} = value},
        context
      ) do
    validate_input_required(operation, Map.delete(value, "resultType"), context)
  end

  def validate_result(_operation, %Result{}, _context), do: :ok

  defp validate_input_required({kind, _target}, value, context) when kind in @operations do
    with :ok <- validate_value(value) do
      require_capabilities(Map.get(value, "inputRequests", %{}), context)
    end
  end

  defp validate_input_required(_operation, _value, _context) do
    {:error, Error.internal("Input-required result is not permitted for this operation")}
  end

  defp validate_value(value) when is_map(value) and not is_struct(value) do
    with true <- JSONValue.valid?(value),
         true <- Map.has_key?(value, "inputRequests") or Map.has_key?(value, "requestState"),
         :ok <- optional_state(value),
         :ok <- validate_requests(Map.get(value, "inputRequests", %{})) do
      :ok
    else
      _invalid -> {:error, Error.internal("Invalid input-required result")}
    end
  end

  defp validate_value(_invalid), do: {:error, Error.internal("Invalid input-required result")}

  defp validate_requests(requests) when is_map(requests) do
    Enum.reduce_while(requests, :ok, fn {_id, request}, :ok ->
      case Elicitation.validate_request(request) do
        :ok -> {:cont, :ok}
        {:error, _reason} -> {:halt, :error}
      end
    end)
  end

  defp validate_requests(_invalid), do: :error

  defp require_capabilities(requests, context) do
    required =
      for {_id, request} <- requests,
          not Elicitation.supported?(request, context.client_capabilities),
          into: %{},
          do: {Map.get(request["params"], "mode", "form"), %{}}

    if map_size(required) == 0 do
      :ok
    else
      {:error,
       %Error{
         code: -32_021,
         kind: :protocol,
         message: "Missing required client capability",
         data: %{"requiredCapabilities" => %{"elicitation" => required}}
       }}
    end
  end
end
