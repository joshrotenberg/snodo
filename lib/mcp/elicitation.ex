defmodule MCP.Elicitation do
  @moduledoc """
  Builds and validates embedded `elicitation/create` requests for MRTR.

  `form/2` and `url/2` return bare input requests, without JSON-RPC envelopes.
  Use `response/3` on a retried request to read only the named input response.
  It does not bind a response to a user or persist state: applications must do
  that using authenticated context and verified, request-specific state.

  Form schemas support the protocol's flat primitive fields and single/multiple
  selection enums, including titled enums and legacy `enumNames`. Unsupported
  schema keywords are rejected rather than silently ignored. Validation uses
  `MCP.Schema.Validator.Basic` for common constraints and explicitly validates
  enum composition and formats. Formats receive syntactic checks, not exhaustive
  RFC validation: email checks address structure, URI requires an absolute URI,
  and date/date-time use ISO calendar parsing with an RFC 3339-shaped timestamp.
  No DNS, URL fetching, or email verification occurs.

  Form mode must never request passwords, API keys, tokens, or payment secrets.
  URL mode accepts HTTP(S) navigation URLs; use HTTPS outside development and
  never put secrets, personal data, or pre-authenticated access in the URL.
  An accepted URL response means consent to navigate, **not** completion of the
  out-of-band interaction. Check completion independently on every retry.
  """

  alias MCP.Error
  alias MCP.JSONValue
  alias MCP.Schema.Validator.Basic

  @type request :: %{String.t() => term()}
  @type response_result :: :missing | {:ok, map()} | {:error, Error.t()}

  @common ~w(type title description default)
  @formats ~w(email uri date date-time)

  @doc "Builds a form input request, raising `ArgumentError` for an invalid schema."
  @spec form(String.t(), map()) :: request()
  def form(message, requested_schema) do
    build(%{
      "mode" => "form",
      "message" => message,
      "requestedSchema" => requested_schema
    })
  end

  @doc "Builds an HTTP(S) URL input request, raising `ArgumentError` when invalid."
  @spec url(String.t(), String.t()) :: request()
  def url(message, url), do: build(%{"mode" => "url", "message" => message, "url" => url})

  @doc "Validates one bare elicitation input request."
  @spec validate_request(term()) :: :ok | {:error, String.t()}
  def validate_request(%{"method" => "elicitation/create", "params" => params} = request) do
    if only_keys?(request, ~w(method params)) and valid_params?(params),
      do: :ok,
      else: {:error, "Invalid elicitation request or restricted requestedSchema"}
  end

  def validate_request(_request), do: {:error, "Expected a bare elicitation/create request"}

  @doc "Checks the requested mode against this request's client capabilities."
  @spec supported?(term(), term()) :: boolean()
  def supported?(request, %{"elicitation" => capability}) when is_map(capability) do
    validate_request(request) == :ok and
      mode_supported?(Map.get(request["params"], "mode", "form"), capability)
  end

  def supported?(_request, _capabilities), do: false

  @doc """
  Reads and validates the named response, ignoring unrelated response IDs.

  Invalid responses return a generic invalid-params error without submitted data.
  Missing form `content` is validated as an empty object. Content on a URL,
  decline, or cancel response is checked for its flat wire shape but not used.
  Additional JSON fields are preserved and ignored.
  This helper does not authenticate content or trust client-echoed request state.
  """
  @spec response(MCP.Context.t() | map(), String.t(), request()) :: response_result()
  def response(context, id, request) when is_map(context) and is_binary(id) do
    with responses when is_map(responses) <- Map.get(context, :input_responses, %{}),
         {:ok, result} <- Map.fetch(responses, id) do
      if validate_request(request) == :ok and valid_response?(result, request["params"]),
        do: {:ok, result},
        else: invalid_response()
    else
      :error -> :missing
      _invalid -> invalid_response()
    end
  end

  def response(_context, _id, _request), do: invalid_response()

  defp build(params) do
    request = %{"method" => "elicitation/create", "params" => params}

    case validate_request(request) do
      :ok -> request
      {:error, message} -> raise ArgumentError, message
    end
  end

  defp valid_params?(%{"message" => message} = params) when is_binary(message) do
    case Map.get(params, "mode", "form") do
      "form" ->
        only_keys?(params, ~w(mode message requestedSchema)) and
          valid_schema?(Map.get(params, "requestedSchema"))

      "url" ->
        only_keys?(params, ~w(mode message url)) and navigation_url?(Map.get(params, "url"))

      _other ->
        false
    end
  end

  defp valid_params?(_params), do: false

  defp valid_schema?(%{"type" => "object", "properties" => properties} = schema)
       when is_map(properties) and not is_struct(properties) do
    only_keys?(schema, ~w($schema type properties required)) and
      optional?(schema, "$schema", &is_binary/1) and
      optional?(schema, "required", &unique_strings?/1) and
      Enum.all?(Map.get(schema, "required", []), &Map.has_key?(properties, &1)) and
      Enum.all?(properties, fn {name, property} ->
        is_binary(name) and valid_property?(property)
      end)
  end

  defp valid_schema?(_schema), do: false

  defp valid_property?(property) when is_map(property) and not is_struct(property) do
    optional?(property, "title", &is_binary/1) and
      optional?(property, "description", &is_binary/1) and
      valid_property_shape?(property) and valid_default?(property)
  end

  defp valid_property?(_property), do: false

  defp valid_property_shape?(%{"type" => "string", "oneOf" => options} = property) do
    only_keys?(property, @common ++ ["oneOf"]) and titled_options?(options)
  end

  defp valid_property_shape?(%{"type" => "string", "enum" => choices} = property) do
    only_keys?(property, @common ++ ~w(enum enumNames)) and choices?(choices) and
      optional?(property, "enumNames", fn names ->
        strings?(names) and length(names) == length(choices)
      end)
  end

  defp valid_property_shape?(%{"type" => "string"} = property) do
    only_keys?(property, @common ++ ~w(minLength maxLength format)) and
      bounds?(property, "minLength", "maxLength", &non_negative_integer?/1) and
      optional?(property, "format", &(&1 in @formats))
  end

  defp valid_property_shape?(%{"type" => type} = property) when type in ["number", "integer"] do
    only_keys?(property, @common ++ ~w(minimum maximum)) and
      bounds?(property, "minimum", "maximum", &is_number/1)
  end

  defp valid_property_shape?(%{"type" => "boolean"} = property) do
    only_keys?(property, @common)
  end

  defp valid_property_shape?(%{"type" => "array", "items" => items} = property) do
    only_keys?(property, @common ++ ~w(minItems maxItems items)) and
      bounds?(property, "minItems", "maxItems", &non_negative_integer?/1) and
      valid_enum_items?(items)
  end

  defp valid_property_shape?(_property), do: false

  defp valid_enum_items?(%{"type" => "string", "enum" => choices} = items) do
    only_keys?(items, ~w(type enum)) and choices?(choices)
  end

  defp valid_enum_items?(%{"anyOf" => options} = items) do
    only_keys?(items, ["anyOf"]) and titled_options?(options)
  end

  defp valid_enum_items?(_items), do: false

  defp valid_default?(property) do
    optional?(property, "default", &valid_property_value?(&1, property))
  end

  defp valid_property_value?(value, property) do
    Basic.validate(value, lower_property(property)) == :ok and extra_constraints?(value, property)
  end

  defp valid_response?(%{"action" => action} = response, params)
       when action in ["accept", "decline", "cancel"] do
    JSONValue.valid?(response) and optional?(response, "content", &flat_content?/1) and
      valid_accepted_content?(response, params)
  end

  defp valid_response?(_response, _params), do: false

  defp valid_accepted_content?(%{"action" => "accept"} = response, params) do
    params["mode"] == "url" or
      valid_content?(Map.get(response, "content", %{}), params["requestedSchema"])
  end

  defp valid_accepted_content?(_response, _params), do: true

  defp valid_content?(content, schema) do
    properties = schema["properties"]
    lowered = Map.new(properties, fn {name, property} -> {name, lower_property(property)} end)

    Basic.validate(content, Map.put(schema, "properties", lowered)) == :ok and
      Enum.all?(properties, fn {name, property} ->
        optional?(content, name, &extra_constraints?(&1, property))
      end)
  end

  defp lower_property(%{"oneOf" => options} = property) do
    property |> Map.delete("oneOf") |> Map.put("enum", Enum.map(options, & &1["const"]))
  end

  defp lower_property(%{"items" => %{"anyOf" => options}} = property) do
    Map.put(property, "items", %{"type" => "string", "enum" => Enum.map(options, & &1["const"])})
  end

  defp lower_property(%{"type" => "string"} = property) do
    Map.drop(property, ~w(minLength maxLength format))
  end

  defp lower_property(property), do: property

  defp extra_constraints?(value, %{"type" => "string"} = property) when is_binary(value) do
    count = value |> String.codepoints() |> length()

    String.valid?(value) and optional?(property, "minLength", &(count >= &1)) and
      optional?(property, "maxLength", &(count <= &1)) and
      optional?(property, "format", &valid_format?(value, &1))
  end

  defp extra_constraints?(_value, _property), do: true

  defp valid_format?(value, "email"), do: Regex.match?(~r/^[^\s@]+@[^\s@]+$/u, value)
  defp valid_format?(value, "uri"), do: absolute_uri?(value)
  defp valid_format?(value, "date"), do: match?({:ok, _date}, Date.from_iso8601(value))

  defp valid_format?(value, "date-time") do
    Regex.match?(
      ~r/^\d{4}-\d{2}-\d{2}[Tt]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:[Zz]|[+-]\d{2}:\d{2})$/,
      value
    ) and
      match?({:ok, _date_time, _offset}, DateTime.from_iso8601(String.upcase(value)))
  end

  defp navigation_url?(value) when is_binary(value) do
    with true <- absolute_uri?(value),
         {:ok, %URI{scheme: scheme, host: host, userinfo: nil}} <- URI.new(value) do
      String.downcase(scheme) in ["http", "https"] and is_binary(host) and host != ""
    else
      _invalid -> false
    end
  end

  defp navigation_url?(_value), do: false

  defp absolute_uri?(value) do
    with true <- String.valid?(value),
         false <- Regex.match?(~r/[\s\x00-\x1f\x7f]/u, value),
         false <- Regex.match?(~r/%(?![0-9a-fA-F]{2})/, value),
         {:ok, %URI{scheme: scheme}} when is_binary(scheme) <- URI.new(value) do
      Regex.match?(~r/^[a-zA-Z][a-zA-Z0-9+.-]*$/, scheme)
    else
      _invalid -> false
    end
  end

  defp mode_supported?("form", capability) when map_size(capability) == 0, do: true
  defp mode_supported?(mode, capability), do: plain_map?(Map.get(capability, mode))

  defp flat_content?(content) when is_map(content) and not is_struct(content) do
    Enum.all?(content, fn {name, value} -> is_binary(name) and flat_value?(value) end)
  end

  defp flat_content?(_content), do: false
  defp flat_value?(value) when is_binary(value), do: String.valid?(value)
  defp flat_value?(value) when is_number(value) or is_boolean(value), do: true
  defp flat_value?(value), do: strings?(value)

  defp choices?(values), do: unique_strings?(values) and values != []

  defp titled_options?(options) when is_list(options) and options != [] do
    Enum.all?(options, fn
      %{"const" => value, "title" => title} = option ->
        is_binary(value) and is_binary(title) and only_keys?(option, ~w(const title))

      _invalid ->
        false
    end) and unique_strings?(Enum.map(options, & &1["const"]))
  end

  defp titled_options?(_options), do: false
  defp strings?(values) when is_list(values), do: Enum.all?(values, &is_binary/1)
  defp strings?(_values), do: false

  defp unique_strings?(values),
    do: strings?(values) and length(values) == length(Enum.uniq(values))

  defp bounds?(schema, lower, upper, predicate) do
    optional?(schema, lower, predicate) and optional?(schema, upper, predicate) and
      (not Map.has_key?(schema, lower) or not Map.has_key?(schema, upper) or
         schema[lower] <= schema[upper])
  end

  defp optional?(map, key, predicate) do
    case Map.fetch(map, key) do
      :error -> true
      {:ok, value} -> predicate.(value)
    end
  end

  defp only_keys?(map, keys), do: not is_struct(map) and Enum.all?(Map.keys(map), &(&1 in keys))
  defp non_negative_integer?(value), do: is_integer(value) and value >= 0
  defp plain_map?(value), do: is_map(value) and not is_struct(value)
  defp invalid_response, do: {:error, Error.invalid_params("Invalid elicitation response")}
end
