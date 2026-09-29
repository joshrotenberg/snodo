defmodule Snodo.Sampling do
  @moduledoc """
  Builds and validates embedded `sampling/createMessage` requests for MRTR.

  SEP-2577 deprecates server-initiated sampling in MCP 2026-07-28. The method
  is still defined by the protocol schema and scored by the official
  conformance runner, so a 2026-07-28 handler may return one as an input
  request through `Snodo.Result.input_required/1`, next to elicitation. Prefer
  elicitation for new designs; sampling stays available for clients that
  declare the `sampling` capability.

  `create_message/2` returns a bare input request, without a JSON-RPC
  envelope. Messages are `Snodo.Prompt.message/2` maps whose content is one
  text, image, audio, tool-use, or tool-result block, or a list of those
  blocks. Use `response/3` on a retried request to read only the named
  `CreateMessageResult`. It does not bind a response to a user or persist
  state: applications must do that using authenticated context and verified,
  request-specific state.

  The dialect refuses the request with `-32021` when the client has not
  declared `sampling`, `sampling.tools` (needed by `:tools` and
  `:tool_choice`), or `sampling.context` (needed by an `:include_context`
  other than `"none"`). Sampled content is model output: treat it as
  untrusted input, never as an instruction or a verified fact.
  """

  alias Snodo.Error
  alias Snodo.JSONValue

  @type request :: %{String.t() => term()}
  @type response_result :: :missing | {:ok, map()} | {:error, Error.t()}

  @method "sampling/createMessage"
  @params ~w(messages maxTokens systemPrompt modelPreferences temperature stopSequences
             includeContext metadata tools toolChoice)
  @options [
    system_prompt: "systemPrompt",
    model_preferences: "modelPreferences",
    temperature: "temperature",
    stop_sequences: "stopSequences",
    include_context: "includeContext",
    metadata: "metadata",
    tools: "tools",
    tool_choice: "toolChoice"
  ]
  @roles ~w(user assistant)
  @media_types ~w(text image audio)
  @context_values ~w(none thisServer allServers)
  @tool_choice_modes ~w(auto none required)
  @priorities ~w(costPriority speedPriority intelligencePriority)
  @common_block ~w(type annotations _meta)
  @resource_link ~w(type uri name title description mimeType size icons annotations _meta)
  @tool ~w(name inputSchema outputSchema title description annotations icons _meta)

  @doc """
  Builds a sampling input request, raising `ArgumentError` when invalid.

  `messages` is a non-empty list of sampling messages. Options:

    * `:max_tokens` - required, a positive integer.
    * `:system_prompt` - a string.
    * `:model_preferences` - a map with optional `"hints"` (a list of
      `%{"name" => string}` maps) and `"costPriority"`, `"speedPriority"`,
      and `"intelligencePriority"` numbers from 0 to 1.
    * `:temperature` - a number.
    * `:stop_sequences` - a list of strings.
    * `:include_context` - `"none"`, `"thisServer"`, or `"allServers"`. The
      last two are deprecated by SEP-2596 and need `sampling.context`.
    * `:metadata` - a JSON object passed through to the client's provider.
    * `:tools` - a list of tool definitions in wire shape; needs
      `sampling.tools`.
    * `:tool_choice` - `%{"mode" => "auto" | "none" | "required"}`; needs
      `sampling.tools`.
  """
  @spec create_message([map()], keyword()) :: request()
  def create_message(messages, opts) when is_list(messages) and is_list(opts) do
    params = %{"messages" => messages, "maxTokens" => Keyword.get(opts, :max_tokens)}

    params =
      Enum.reduce(@options, params, fn {option, key}, params ->
        case Keyword.fetch(opts, option) do
          {:ok, value} -> Map.put(params, key, value)
          :error -> params
        end
      end)

    request = %{"method" => @method, "params" => params}

    case validate_request(request) do
      :ok -> request
      {:error, message} -> raise ArgumentError, message
    end
  end

  @doc "Validates one bare sampling input request."
  @spec validate_request(term()) :: :ok | {:error, String.t()}
  def validate_request(%{"method" => @method, "params" => params} = request) do
    cond do
      not only_keys?(request, ~w(method params)) ->
        {:error, "Expected a bare sampling/createMessage request"}

      not (only_keys?(params, @params) and JSONValue.valid?(params)) ->
        {:error, "sampling/createMessage params contain an unsupported key or non-JSON value"}

      true ->
        validate_params(params)
    end
  end

  def validate_request(_request), do: {:error, "Expected a bare sampling/createMessage request"}

  @doc """
  Checks the request against this request's client capabilities.

  Requires a `sampling` object, plus `sampling.tools` when the request carries
  `tools` or `toolChoice` and `sampling.context` when `includeContext` is not
  `"none"`.
  """
  @spec supported?(term(), term()) :: boolean()
  def supported?(request, %{"sampling" => capability})
      when is_map(capability) and not is_struct(capability) do
    validate_request(request) == :ok and
      Enum.all?(required_settings(request["params"]), &plain_map?(Map.get(capability, &1)))
  end

  def supported?(_request, _capabilities), do: false

  @doc false
  @spec required_capability(request()) :: {String.t(), map()}
  def required_capability(%{"params" => params}) do
    {"sampling", Map.new(required_settings(params), &{&1, %{}})}
  end

  @doc """
  Reads and validates the named response, ignoring unrelated response IDs.

  A valid response is a `CreateMessageResult`: a `"role"`, one sampling
  content block or a list of them as `"content"`, a `"model"` string, and an
  optional `"stopReason"`. Invalid responses return a generic invalid-params
  error without the submitted data. Additional JSON fields are preserved and
  ignored. This helper does not authenticate content or trust client-echoed
  request state.
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

  defp validate_params(params) do
    with :ok <-
           check(
             messages?(params["messages"]),
             "messages must be a non-empty list of user or assistant sampling messages"
           ),
         :ok <-
           check(positive_integer?(params["maxTokens"]), "maxTokens must be a positive integer"),
         :ok <-
           check(optional?(params, "systemPrompt", &is_binary/1), "systemPrompt must be a string"),
         :ok <-
           check(
             optional?(params, "modelPreferences", &model_preferences?/1),
             "modelPreferences must contain hints and priorities from 0 to 1"
           ),
         :ok <-
           check(optional?(params, "temperature", &is_number/1), "temperature must be a number"),
         :ok <-
           check(
             optional?(params, "stopSequences", &strings?/1),
             "stopSequences must be a list of strings"
           ),
         :ok <-
           check(
             optional?(params, "includeContext", &(&1 in @context_values)),
             "includeContext must be none, thisServer, or allServers"
           ),
         :ok <- check(optional?(params, "metadata", &plain_map?/1), "metadata must be an object"),
         :ok <-
           check(
             optional?(params, "tools", &tools?/1),
             "tools must be a list of tool definitions"
           ) do
      check(
        optional?(params, "toolChoice", &tool_choice?/1),
        "toolChoice must be an object with an auto, none, or required mode"
      )
    end
  end

  defp check(true, _message), do: :ok
  defp check(false, message), do: {:error, message}

  defp required_settings(params) when is_map(params) do
    tools =
      if Map.has_key?(params, "tools") or Map.has_key?(params, "toolChoice"),
        do: ["tools"],
        else: []

    if Map.get(params, "includeContext", "none") == "none", do: tools, else: tools ++ ["context"]
  end

  defp required_settings(_params), do: []

  defp valid_response?(%{"role" => role, "content" => content, "model" => model} = response)
       when role in @roles and is_binary(model) do
    JSONValue.valid?(response) and message_content?(content) and
      optional?(response, "stopReason", &is_binary/1) and meta?(response)
  end

  defp valid_response?(_response), do: false

  defp messages?(messages) when is_list(messages) and messages != [],
    do: Enum.all?(messages, &message?/1)

  defp messages?(_messages), do: false

  defp message?(%{"role" => role, "content" => content} = message) when role in @roles do
    only_keys?(message, ~w(role content _meta)) and meta?(message) and message_content?(content)
  end

  defp message?(_message), do: false

  defp message_content?(blocks) when is_list(blocks) and blocks != [],
    do: Enum.all?(blocks, &sampling_block?/1)

  defp message_content?(block), do: sampling_block?(block)

  # SamplingMessageContentBlock: text, image, audio, tool_use, or tool_result.
  defp sampling_block?(%{"type" => type} = block) when type in @media_types,
    do: media_block?(block)

  defp sampling_block?(
         %{"type" => "tool_use", "id" => id, "name" => name, "input" => input} = block
       ) do
    is_binary(id) and is_binary(name) and plain_map?(input) and
      only_keys?(block, ~w(type id name input _meta)) and meta?(block)
  end

  defp sampling_block?(
         %{"type" => "tool_result", "toolUseId" => id, "content" => content} = block
       ) do
    is_binary(id) and is_list(content) and Enum.all?(content, &content_block?/1) and
      optional?(block, "isError", &is_boolean/1) and
      only_keys?(block, ~w(type toolUseId content isError structuredContent _meta)) and
      meta?(block)
  end

  defp sampling_block?(_block), do: false

  # ContentBlock, as in a tool result: text, image, audio, resource link, or
  # embedded resource.
  defp content_block?(%{"type" => type} = block) when type in @media_types,
    do: media_block?(block)

  defp content_block?(%{"type" => "resource_link", "uri" => uri, "name" => name} = block) do
    is_binary(uri) and is_binary(name) and only_keys?(block, @resource_link) and
      Enum.all?(~w(title description mimeType), &optional?(block, &1, fn v -> is_binary(v) end)) and
      optional?(block, "size", &is_integer/1) and optional?(block, "icons", &icons?/1) and
      annotations?(block)
  end

  defp content_block?(%{"type" => "resource", "resource" => resource} = block) do
    resource_contents?(resource) and only_keys?(block, ~w(type resource annotations _meta)) and
      annotations?(block)
  end

  defp content_block?(_block), do: false

  defp media_block?(%{"type" => "text", "text" => text} = block) do
    is_binary(text) and only_keys?(block, ["text" | @common_block]) and annotations?(block)
  end

  defp media_block?(%{"type" => _type, "data" => data, "mimeType" => mime_type} = block) do
    is_binary(data) and is_binary(mime_type) and
      only_keys?(block, ~w(data mimeType) ++ @common_block) and annotations?(block)
  end

  defp media_block?(_block), do: false

  defp resource_contents?(%{"uri" => uri} = resource) when is_binary(uri) do
    only_keys?(resource, ~w(uri text blob mimeType _meta)) and
      is_binary(resource["text"]) != is_binary(resource["blob"]) and
      optional?(resource, "mimeType", &is_binary/1) and meta?(resource)
  end

  defp resource_contents?(_resource), do: false

  defp annotations?(block) do
    meta?(block) and
      optional?(block, "annotations", fn annotations ->
        plain_map?(annotations) and only_keys?(annotations, ~w(audience priority lastModified)) and
          optional?(annotations, "audience", &roles?/1) and
          optional?(annotations, "priority", &priority?/1) and
          optional?(annotations, "lastModified", &is_binary/1)
      end)
  end

  defp model_preferences?(preferences) do
    plain_map?(preferences) and only_keys?(preferences, ["hints" | @priorities]) and
      optional?(preferences, "hints", &hints?/1) and
      Enum.all?(@priorities, &optional?(preferences, &1, fn v -> priority?(v) end))
  end

  # Hint keys beyond name are left to the client by the schema.
  defp hints?(hints) when is_list(hints),
    do: Enum.all?(hints, &(plain_map?(&1) and optional?(&1, "name", fn v -> is_binary(v) end)))

  defp hints?(_hints), do: false

  defp tools?(tools) when is_list(tools), do: Enum.all?(tools, &tool?/1)
  defp tools?(_tools), do: false

  defp tool?(%{"name" => name, "inputSchema" => %{"type" => "object"} = schema} = tool)
       when is_binary(name) and name != "" do
    plain_map?(schema) and only_keys?(tool, @tool) and
      optional?(tool, "outputSchema", &plain_map?/1) and
      optional?(tool, "annotations", &plain_map?/1) and
      Enum.all?(~w(title description), &optional?(tool, &1, fn v -> is_binary(v) end)) and
      optional?(tool, "icons", &icons?/1) and meta?(tool)
  end

  defp tool?(_tool), do: false

  defp tool_choice?(%{"mode" => mode} = choice),
    do: mode in @tool_choice_modes and only_keys?(choice, ["mode"])

  defp tool_choice?(choice), do: plain_map?(choice) and map_size(choice) == 0

  defp icons?(icons) when is_list(icons),
    do: Enum.all?(icons, &(plain_map?(&1) and is_binary(Map.get(&1, "src"))))

  defp icons?(_icons), do: false

  defp roles?(roles) when is_list(roles), do: Enum.all?(roles, &(&1 in @roles))
  defp roles?(_roles), do: false
  defp priority?(value), do: is_number(value) and value >= 0 and value <= 1
  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp strings?(values) when is_list(values), do: Enum.all?(values, &is_binary/1)
  defp strings?(_values), do: false
  defp meta?(map), do: optional?(map, "_meta", &plain_map?/1)

  defp optional?(map, key, predicate) do
    case Map.fetch(map, key) do
      :error -> true
      {:ok, value} -> predicate.(value)
    end
  end

  defp only_keys?(map, keys), do: plain_map?(map) and Enum.all?(Map.keys(map), &(&1 in keys))
  defp plain_map?(value), do: is_map(value) and not is_struct(value)
  defp invalid_response, do: {:error, Error.invalid_params("Invalid sampling response")}
end
