defmodule Snodo.Resource.Template do
  @moduledoc """
  An exact matcher for the RFC 6570 URI template shapes that can be matched
  without ambiguity.

  `Snodo.Resource` compiles a template at build time and generates
  `matches?/1` from the result. A template outside the supported shapes is a
  compile error naming the shape, unless the module implements `matches?/1`
  itself. This module matches URIs against templates; it does not expand them.

  ## Supported shapes

    * The scheme is a literal, matched case-insensitively.
    * The authority is one literal, one `{var}`, or empty when a literal `/`
      follows it, as in `file:///{+path}`. An empty authority matches only an
      empty host.
    * Each path segment is one literal or one `{var}`. A `{var}` binds exactly
      one whole, non-empty segment.
    * At most one variable-length path expression, anywhere in the path:
      * `/{+var}` (reserved expansion) binds one or more whole segments,
        joined with `/`;
      * `{/var}` (path segment expansion) binds zero or one segment;
      * `{/var*}` (exploded path segments) binds zero or more segments,
        joined with `/`.

      The literal and `{var}` segments before and after it are matched from
      each end, so there is never more than one way to split a URI.
    * Query expansion at the end of the template: one `{?a,b}` followed by any
      number of `{&c,d}`. Each named parameter may appear at most once, in any
      order, and may be absent. A parameter that the template does not name,
      a repeated parameter, a pair without `=`, or an empty query does not
      match. `q=` binds `""`.

  A variable that is not bound, an absent `{/var}`, `{/var*}`, or query
  parameter, is left out of the returned map, as RFC 6570 leaves undefined
  variables out of an expansion.

  ## Rejected shapes

  `compile/1` returns `{:error, reason}`, and the reason names the shape, for:
  fragment expansion `{#var}`, label expansion `{.var}`, path-style parameters
  `{;var}`, the reserved operators `= , ! @ |`, prefix modifiers `{var:n}`,
  explode on simple, reserved, or query variables, more than one variable in a
  simple, reserved, or path expression (`{a,b}`, `{/a,b}`: a missing value
  cannot be assigned to one variable), more than one variable-length path
  expression, an expression that shares a path segment with literal text or
  another expression (`v{version}`, `{name}.json`), any expression in the
  scheme, a reserved expression in the authority, an empty authority not
  followed by `/`, a `{/var}` straight after a literal `/`, a query expression
  that is not at the end, a literal query, fragment, port, or userinfo, empty
  segments,
  variables named `uri` or `_meta` (the request owns those keys), and
  malformed literals.

  ## Values

  Matched values are percent-decoded once and must be valid UTF-8. Malformed
  percent escapes and empty path segments do not match. `+` is not decoded as
  a space. Repeated variables must bind the same decoded value. Literal
  authority and path segments match exactly, without percent-decoding or
  slash normalization, and dot segments (`.` and `..`) are not removed.

  A decoded value can therefore contain `/` (from `%2F`, or from the segments
  that `{+var}` and `{/var*}` join), can be `..` or contain `../`, and can
  contain a NUL byte (from `%00`). An application that maps a value to a file
  must treat it as untrusted: reject values containing NUL, and resolve the
  rest with `Path.safe_relative/2` against the directory it serves (or reject
  values containing `/`, `\\`, or `..` segments) before touching the file
  system.

  ## Limits

  A template is at most 1,024 bytes with at most 32 variables, checked
  when it compiles. Matching is linear in the length of the URI: the URI is
  parsed once, split once on `/`, and each fixed segment and query pair is
  examined once, with no backtracking. The span a variable-length expression
  binds is checked and decoded as one binary, not segment by segment. A query with more pairs than the template names
  is refused before the rest is read. The length of the URI is bounded by the
  transport's message size limit.
  """

  @type variables :: %{optional(String.t()) => String.t()}
  @type part :: {:literal, String.t()} | {:variable, String.t()}
  @type expansion ::
          {:reserved, String.t()} | {:optional, String.t()} | {:explode, String.t()}
  @type t :: %__MODULE__{
          scheme: String.t(),
          authority: part(),
          segments: [part()],
          expansion: expansion() | nil,
          suffix: [part()],
          query: [String.t()]
        }

  @enforce_keys [:scheme, :authority]
  defstruct [:scheme, :authority, segments: [], expansion: nil, suffix: [], query: []]

  @max_template_bytes 1024
  @max_variables 32

  @scheme ~r/\A[A-Za-z][A-Za-z0-9+.-]*\z/
  @name ~r/\A[A-Za-z0-9_.-]+\z/
  @invalid_escape ~r/%(?![A-Fa-f0-9]{2})/

  # A port or userinfo in a requested URI's authority never matches.
  @reserved ["?", "#", "@", ":"]

  @shared_segment "a path segment that holds literal text and an expression, or two expressions"

  @doc """
  Compiles a URI template, or reports why it is outside the supported shapes.

  `URI.new/1` rejects the braces, so the template is parsed textually. Its
  literals are checked as a concrete URI with safe placeholders for variables,
  so an invalid literal cannot produce an unreachable generated matcher.
  """
  @spec compile(String.t()) :: {:ok, t()} | {:error, String.t()}
  def compile(uri_template) when is_binary(uri_template) do
    with :ok <- check_size(uri_template),
         {:ok, scheme, rest} <- split_scheme(uri_template),
         {:ok, tokens} <- tokenize(rest, "", []),
         :ok <- check_delimiters(tokens),
         :ok <- check_variables(tokens),
         {:ok, hier, query} <- split_query(tokens),
         {:ok, authority, items} <- split_authority(stream(hier)),
         {:ok, path} <- compile_path(items, []),
         {:ok, segments, expansion, suffix} <- split_expansion(path),
         template = %__MODULE__{
           scheme: scheme,
           authority: authority,
           segments: segments,
           expansion: expansion,
           suffix: suffix,
           query: query
         },
         :ok <- validate_literal_uri(template) do
      {:ok, template}
    end
  end

  @doc """
  Matches a concrete URI, returning the bound variables.
  """
  @spec match(t(), String.t()) :: {:ok, variables()} | :error
  def match(%__MODULE__{} = template, uri) when is_binary(uri) do
    with true <- String.valid?(uri),
         {:ok, parsed} <- URI.new(uri),
         :ok <- validate_uri(parsed, template, template.query != []),
         {:ok, authority, path, query} <- split_uri(uri, template.scheme),
         {:ok, bound} <- bind(template.authority, authority, %{}),
         {:ok, bound} <- bind_path(template, path, bound) do
      bind_query(template.query, query, bound)
    else
      _no_match -> :error
    end
  end

  @doc "Returns the variable names a compiled template binds, in template order."
  @spec variables(t()) :: [String.t()]
  def variables(%__MODULE__{} = template) do
    parts =
      [template.authority | template.segments] ++
        List.wrap(template.expansion) ++ template.suffix

    for({kind, name} <- parts, kind != :literal, do: name) ++ template.query
  end

  ## Compilation

  defp check_size(template) when byte_size(template) > @max_template_bytes,
    do: {:error, "a template longer than #{@max_template_bytes} bytes"}

  defp check_size(_template), do: :ok

  defp split_scheme(template) do
    with [scheme, rest] <- String.split(template, "://", parts: 2),
         true <- Regex.match?(@scheme, scheme) do
      {:ok, String.downcase(scheme), rest}
    else
      _invalid -> {:error, "a scheme that is not a literal followed by ://"}
    end
  end

  # Splits the text after the scheme into literal text and expressions.
  defp tokenize("", "", acc), do: {:ok, Enum.reverse(acc)}
  defp tokenize("", literal, acc), do: {:ok, Enum.reverse([{:literal, literal} | acc])}

  defp tokenize("{" <> rest, literal, acc) do
    acc = if literal == "", do: acc, else: [{:literal, literal} | acc]

    with [body, rest] <- :binary.split(rest, "}"),
         false <- String.contains?(body, "{") do
      case expression(body) do
        {:ok, expression} -> tokenize(rest, "", [expression | acc])
        {:error, _reason} = error -> error
      end
    else
      _unclosed -> {:error, "an unclosed or nested expression"}
    end
  end

  defp tokenize("}" <> _rest, _literal, _acc), do: {:error, "a } outside an expression"}

  defp tokenize(<<char::utf8, rest::binary>>, literal, acc),
    do: tokenize(rest, literal <> <<char::utf8>>, acc)

  defp tokenize(_invalid, _literal, _acc), do: {:error, "a template that is not valid UTF-8"}

  defp expression(body) do
    {operator, list} =
      case body do
        <<op, list::binary>> when op in ~c"+#./;?&=,!@|" -> {<<op>>, list}
        list -> {"", list}
      end

    with :ok <- supported_operator(operator),
         {:ok, specs} <- varspecs(String.split(list, ","), []) do
      {:ok, {:expression, operator, specs}}
    end
  end

  defp varspecs([], acc), do: {:ok, Enum.reverse(acc)}

  defp varspecs([spec | rest], acc) do
    with {:ok, parsed} <- varspec(spec), do: varspecs(rest, [parsed | acc])
  end

  defp supported_operator(op) when op in ["", "+", "/", "?", "&"], do: :ok
  defp supported_operator("#"), do: {:error, "fragment expansion ({#var})"}
  defp supported_operator("."), do: {:error, "label expansion ({.var})"}
  defp supported_operator(";"), do: {:error, "path-style parameter expansion ({;var})"}
  defp supported_operator(op), do: {:error, "the reserved operator #{op}"}

  defp varspec(spec) do
    {name, explode?} =
      case String.split_at(spec, -1) do
        {name, "*"} -> {name, true}
        _plain -> {spec, false}
      end

    cond do
      String.contains?(spec, ":") -> {:error, "a prefix modifier ({var:n})"}
      not Regex.match?(@name, name) -> {:error, "an invalid variable name #{inspect(spec)}"}
      name in ["uri", "_meta"] -> {:error, "a variable named #{name}, which the request owns"}
      true -> {:ok, {name, explode?}}
    end
  end

  defp check_delimiters(tokens) do
    Enum.find_value(tokens, :ok, fn
      {:literal, text} -> delimiter_error(text)
      _expression -> nil
    end)
  end

  defp delimiter_error(text) do
    cond do
      String.contains?(text, "?") -> {:error, "a literal query"}
      String.contains?(text, "#") -> {:error, "a literal fragment"}
      String.contains?(text, "@") -> {:error, "userinfo"}
      String.contains?(text, ":") -> {:error, "a port or a colon in literal text"}
      true -> nil
    end
  end

  defp check_variables(tokens) do
    count = Enum.sum(for {:expression, _op, specs} <- tokens, do: length(specs))

    if count > @max_variables,
      do: {:error, "more than #{@max_variables} variables"},
      else: :ok
  end

  # Query expressions must end the template: one {?...}, then any {&...}.
  defp split_query(tokens) do
    {hier, query} = Enum.split_while(tokens, &(not query_expression?(&1)))

    cond do
      query == [] ->
        {:ok, hier, []}

      not Enum.all?(query, &query_expression?/1) ->
        {:error, "literal text or a path expression after a query expression"}

      not match?([{:expression, "?", _specs} | _rest], query) ->
        {:error, "a {&var} continuation without a preceding {?var}"}

      Enum.any?(tl(query), &match?({:expression, "?", _specs}, &1)) ->
        {:error, "more than one {?var} expression"}

      true ->
        with {:ok, names} <- query_names(query), do: {:ok, hier, names}
    end
  end

  defp query_names(query) do
    specs = Enum.flat_map(query, fn {:expression, _op, specs} -> specs end)
    names = Enum.map(specs, &elem(&1, 0))

    cond do
      Enum.any?(specs, &elem(&1, 1)) -> {:error, "an exploded query variable ({?var*})"}
      Enum.uniq(names) != names -> {:error, "a query variable named more than once"}
      true -> {:ok, names}
    end
  end

  defp query_expression?({:expression, op, _specs}), do: op in ["?", "&"]
  defp query_expression?(_token), do: false

  # Literal text becomes its pieces with a :slash marker for each "/".
  defp stream(tokens) do
    Enum.flat_map(tokens, fn
      {:literal, text} ->
        text
        |> String.split("/")
        |> Enum.map(&{:text, &1})
        |> Enum.intersperse(:slash)
        |> Enum.reject(&(&1 == {:text, ""}))

      expression ->
        [expression]
    end)
  end

  defp split_authority(items) do
    {authority, path} = Enum.split_while(items, &(not path_boundary?(&1)))

    case authority do
      [{:text, text}] ->
        with {:ok, part} <- literal(text), do: {:ok, part, path}

      [{:expression, "", [{name, false}]}] ->
        {:ok, {:variable, name}, path}

      [] ->
        # An empty authority, as in file:///path, is unambiguous only when a
        # literal / starts the path.
        if match?([:slash | _rest], path),
          do: {:ok, {:literal, ""}, path},
          else: {:error, "an empty authority that is not followed by /"}

      [{:expression, "+", _specs}] ->
        {:error, "reserved expansion ({+var}) in the authority"}

      _other ->
        {:error, "an authority that is not one literal or one {var}"}
    end
  end

  defp path_boundary?(:slash), do: true
  defp path_boundary?({:expression, "/", _specs}), do: true
  defp path_boundary?(_item), do: false

  defp compile_path([], acc), do: {:ok, Enum.reverse(acc)}

  defp compile_path([:slash, {:expression, "/", _specs} | _rest], _acc),
    do: {:error, "a {/var} expression after a literal /, which would leave an empty segment"}

  defp compile_path([:slash | rest], acc) do
    {segment, rest} = Enum.split_while(rest, &(not path_boundary?(&1)))

    with {:ok, part} <- compile_segment(segment), do: compile_path(rest, [part | acc])
  end

  defp compile_path([{:expression, "/", specs} | rest], acc) do
    case specs do
      [{name, false}] -> compile_path(rest, [{:optional, name} | acc])
      [{name, true}] -> compile_path(rest, [{:explode, name} | acc])
      _several -> {:error, "more than one variable in a path expression ({/a,b})"}
    end
  end

  # Text or an expression straight after a path expression, as in {/a}x.
  defp compile_path(_items, _acc), do: {:error, @shared_segment}

  defp compile_segment([]), do: {:error, "an empty path segment"}
  defp compile_segment([{:text, text}]), do: literal(text)

  defp compile_segment([{:expression, op, specs}]) when op in ["", "+"] do
    case {op, specs} do
      {"", [{name, false}]} -> {:ok, {:variable, name}}
      {"+", [{name, false}]} -> {:ok, {:reserved, name}}
      {_op, [{_name, true}]} -> {:error, "an exploded simple or reserved variable ({var*})"}
      _several -> {:error, "more than one variable in a simple or reserved expression ({a,b})"}
    end
  end

  defp compile_segment(_mixed), do: {:error, @shared_segment}

  defp literal(text) do
    case decode(text) do
      {:ok, _decoded} -> {:ok, {:literal, text}}
      :error -> {:error, "a malformed percent escape or non-UTF-8 literal"}
    end
  end

  defp split_expansion(path) do
    case Enum.split_with(path, &variable_length?/1) do
      {[], _fixed} ->
        {:ok, path, nil, []}

      {[expansion], _fixed} ->
        {segments, [^expansion | suffix]} = Enum.split_while(path, &(&1 != expansion))
        {:ok, segments, expansion, suffix}

      {_several, _fixed} ->
        {:error, "more than one variable-length path expression ({+var}, {/var}, or {/var*})"}
    end
  end

  defp variable_length?({kind, _name}), do: kind in [:reserved, :optional, :explode]

  defp validate_literal_uri(%__MODULE__{} = template) do
    parts =
      Enum.map(
        [template.authority | template.segments] ++
          List.wrap(template.expansion) ++ template.suffix,
        fn
          {:literal, value} -> value
          {_variable, _name} -> "mcp-variable"
        end
      )

    with {:ok, uri} <- URI.new(template.scheme <> "://" <> Enum.join(parts, "/")),
         :ok <- validate_uri(uri, template, false) do
      :ok
    else
      _invalid -> {:error, "literal text that is not valid in a URI"}
    end
  end

  ## Matching

  defp validate_uri(%URI{} = uri, %__MODULE__{} = template, query?) do
    # Only a template with an empty authority matches an empty host.
    empty_host? = template.authority == {:literal, ""}

    if uri.scheme == template.scheme and is_binary(uri.host) and uri.host == "" == empty_host? and
         (is_nil(uri.query) or (query? and uri.query != "")) and
         is_nil(uri.fragment) and is_nil(uri.userinfo) do
      :ok
    else
      :error
    end
  end

  defp split_uri(uri, scheme) do
    # URI.new/1 normalizes an absent port and an explicit default port to the
    # same value. Check the original authority, and preserve empty path parts.
    with [input_scheme, rest] <- String.split(uri, "://", parts: 2),
         true <- String.downcase(input_scheme) == scheme,
         {hier, query} <- split_at_query(rest),
         {authority, path} <- split_at_path(hier),
         false <- String.contains?(authority, @reserved) do
      {:ok, authority, path, query}
    else
      _unsupported -> :error
    end
  end

  # The path is everything after the authority's /, or nil without one.
  defp split_at_path(hier) do
    case :binary.split(hier, "/") do
      [authority] -> {authority, nil}
      [authority, path] -> {authority, path}
    end
  end

  defp path_segments(nil), do: []
  defp path_segments(path), do: String.split(path, "/")

  defp split_at_query(rest) do
    case :binary.split(rest, "?") do
      [hier] -> {hier, nil}
      [hier, query] -> {hier, query}
    end
  end

  defp bind_path(%__MODULE__{expansion: nil, segments: parts}, path, bound) do
    segments = path_segments(path)

    if length(segments) == length(parts), do: bind_segments(parts, segments, bound), else: :error
  end

  defp bind_path(%__MODULE__{} = template, path, bound) do
    # The fixed segments are matched from each end; the variable-length
    # expression takes the bytes between them, which are checked and decoded
    # as one binary rather than segment by segment.
    segments = path_segments(path)
    count = length(segments) - length(template.segments) - length(template.suffix)

    with true <- count >= 0 and span_fits?(template.expansion, count),
         prefix = Enum.take(segments, length(template.segments)),
         suffix = take_last(segments, length(template.suffix)),
         {:ok, bound} <- bind_segments(template.segments, prefix, bound),
         {:ok, bound} <- bind_segments(template.suffix, suffix, bound) do
      if count == 0,
        do: {:ok, bound},
        else: bind_span(template.expansion, span(path, prefix, suffix), bound)
    else
      _no_match -> :error
    end
  end

  defp take_last(_segments, 0), do: []
  defp take_last(segments, count), do: Enum.take(segments, -count)

  defp span(path, prefix, suffix) do
    start = Enum.reduce(prefix, 0, &(byte_size(&1) + 1 + &2))
    trailing = Enum.reduce(suffix, 0, &(byte_size(&1) + 1 + &2))
    binary_part(path, start, byte_size(path) - start - trailing)
  end

  defp span_fits?({:reserved, _name}, count), do: count >= 1
  defp span_fits?({:optional, _name}, count), do: count <= 1
  defp span_fits?({:explode, _name}, _count), do: true

  # One or more segments joined by /. No escape can cross a /, so decoding the
  # span once equals decoding each segment. An empty segment shows as an empty
  # span, a leading or trailing /, or //.
  defp bind_span({_kind, name}, span, bound) do
    with false <- span == "",
         false <- String.starts_with?(span, "/") or String.ends_with?(span, "/"),
         false <- String.contains?(span, "//"),
         {:ok, decoded} <- decode(span) do
      bind_value(name, decoded, bound)
    else
      _invalid -> :error
    end
  end

  defp bind_segments(parts, segments, bound) do
    parts
    |> Enum.zip(segments)
    |> Enum.reduce_while({:ok, bound}, fn {part, segment}, {:ok, acc} ->
      case bind(part, segment, acc) do
        {:ok, next} -> {:cont, {:ok, next}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp bind({:literal, expected}, value, bound) do
    if expected == value, do: {:ok, bound}, else: :error
  end

  defp bind({:variable, _name}, "", _bound), do: :error

  defp bind({:variable, name}, value, bound) do
    with {:ok, decoded} <- decode(value), do: bind_value(name, decoded, bound)
  end

  defp bind_query(_names, nil, bound), do: {:ok, bound}
  defp bind_query(names, query, bound), do: bind_pairs(query, names, [], bound)

  # Reads one pair at a time and stops at the first parameter the template does
  # not name, so a long query is not split up front.
  defp bind_pairs(query, names, seen, bound) do
    {pair, rest} =
      case :binary.split(query, "&") do
        [pair] -> {pair, nil}
        [pair, rest] -> {pair, rest}
      end

    with [name, value] <- :binary.split(pair, "="),
         true <- name in names and name not in seen,
         {:ok, decoded} <- decode(value),
         {:ok, bound} <- bind_value(name, decoded, bound) do
      if is_nil(rest), do: {:ok, bound}, else: bind_pairs(rest, names, [name | seen], bound)
    else
      _no_match -> :error
    end
  end

  defp bind_value(name, decoded, bound) do
    case Map.fetch(bound, name) do
      :error -> {:ok, Map.put(bound, name, decoded)}
      {:ok, ^decoded} -> {:ok, bound}
      {:ok, _different} -> :error
    end
  end

  # Percent-decodes once. Malformed escapes and invalid UTF-8 are errors. A
  # value without % is returned as it is, after the UTF-8 check.
  defp decode(value) do
    cond do
      not String.contains?(value, "%") ->
        if String.valid?(value), do: {:ok, value}, else: :error

      Regex.match?(@invalid_escape, value) ->
        :error

      true ->
        decoded = URI.decode(value)
        if String.valid?(decoded), do: {:ok, decoded}, else: :error
    end
  end
end
