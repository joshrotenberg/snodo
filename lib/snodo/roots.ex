defmodule Snodo.Roots do
  @moduledoc """
  Builds and validates embedded `roots/list` requests for MRTR.

  SEP-2577 deprecates server-initiated roots listing in MCP 2026-07-28. The
  method is still defined by the protocol schema and scored by the official
  conformance runner, so a 2026-07-28 handler may return one as an input
  request through `Snodo.Result.input_required/1`, next to elicitation.

  `list/0` returns a bare input request, without a JSON-RPC envelope. Use
  `response/3` on a retried request to read only the named `ListRootsResult`.
  The dialect refuses the request with `-32021` when the client has not
  declared `roots`. Each root URI must start with `file://`, as the 2026-07-28
  schema requires. The client chooses which roots to reveal, and a root is a
  claim about the client's file system, not an access grant: check every path
  an application derives from one against its own authorization.
  """

  alias Snodo.Error
  alias Snodo.JSONValue

  @type request :: %{String.t() => term()}
  @type response_result :: :missing | {:ok, map()} | {:error, Error.t()}

  @method "roots/list"

  @doc "Builds a roots input request."
  @spec list() :: request()
  def list, do: %{"method" => @method, "params" => %{}}

  @doc """
  Validates one bare roots input request.

  The schema makes `params` optional; when present it may carry only `_meta`,
  itself an object.
  """
  @spec validate_request(term()) :: :ok | {:error, String.t()}
  def validate_request(%{"method" => @method} = request) do
    if only_keys?(request, ~w(method params)) and optional?(request, "params", &params?/1),
      do: :ok,
      else: {:error, "Expected a bare roots/list request with at most _meta in params"}
  end

  def validate_request(_request), do: {:error, "Expected a bare roots/list request"}

  @doc "Checks the request against this request's client capabilities."
  @spec supported?(term(), term()) :: boolean()
  def supported?(request, %{"roots" => capability})
      when is_map(capability) and not is_struct(capability) do
    validate_request(request) == :ok
  end

  def supported?(_request, _capabilities), do: false

  @doc false
  @spec required_capability(request()) :: {String.t(), map()}
  def required_capability(_request), do: {"roots", %{}}

  @doc """
  Reads and validates the named response, ignoring unrelated response IDs.

  A valid response is a `ListRootsResult`: a `"roots"` list whose entries
  carry a `file://` `"uri"` and an optional `"name"`. Invalid responses return
  a generic invalid-params error without the submitted data. Additional JSON
  fields are preserved and ignored. This helper does not authenticate content
  or trust client-echoed request state.
  """
  @spec response(Snodo.Context.t() | map(), String.t(), request()) :: response_result()
  def response(context, id, request) when is_map(context) and is_binary(id) do
    with responses when is_map(responses) <- Map.get(context, :input_responses, %{}),
         {:ok, result} <- Map.fetch(responses, id) do
      if validate_request(request) == :ok and valid_response?(result),
        do: {:ok, result},
        else: invalid_response()
    else
      :error -> :missing
      _invalid -> invalid_response()
    end
  end

  def response(_context, _id, _request), do: invalid_response()

  @doc """
  Checks that `response` is a `ListRootsResult`.

  That is a `"roots"` list, possibly empty, whose entries carry a `file://`
  `"uri"` and an optional `"name"`. Additional JSON fields are allowed.
  `Snodo.Client` applies it to what a roots handler returns.
  """
  @spec valid_response?(term()) :: boolean()
  def valid_response?(%{"roots" => roots} = response) when is_list(roots) do
    JSONValue.valid?(response) and Enum.all?(roots, &root?/1)
  end

  def valid_response?(_response), do: false

  defp root?(%{"uri" => uri} = root) when is_binary(uri) do
    String.starts_with?(uri, "file://") and match?({:ok, %URI{}}, URI.new(uri)) and
      optional?(root, "name", &is_binary/1) and optional?(root, "_meta", &plain_map?/1)
  end

  defp root?(_root), do: false

  defp params?(params),
    do: only_keys?(params, ["_meta"]) and optional?(params, "_meta", &plain_map?/1)

  defp optional?(map, key, predicate) do
    case Map.fetch(map, key) do
      :error -> true
      {:ok, value} -> predicate.(value)
    end
  end

  defp only_keys?(map, keys), do: plain_map?(map) and Enum.all?(Map.keys(map), &(&1 in keys))
  defp plain_map?(value), do: is_map(value) and not is_struct(value)
  defp invalid_response, do: {:error, Error.invalid_params("Invalid roots response")}
end
