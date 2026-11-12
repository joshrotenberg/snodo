defmodule Snodo.Skills.Frontmatter do
  @moduledoc """
  Reads the YAML frontmatter at the top of a SKILL.md file.

  The core has no YAML dependency, so this module reads a subset of YAML 1.2
  that covers the frontmatter skills use in practice:

    * a top-level block mapping of `key: value` lines, with plain or quoted
      keys;
    * plain scalars, resolved by the YAML 1.2 core schema: `null`, `~`, or an
      empty value is `nil`, `true` and `false` are booleans, decimal, `0x`,
      and `0o` integers and decimal floats are numbers, and anything else is
      a string. A plain scalar may continue on more deeply indented lines,
      which fold into one line;
    * single- and double-quoted strings on one line, with the YAML escapes;
    * flow sequences of scalars on one line, such as `[Read, Bash]`;
    * block sequences of scalars (`- item` lines) under a key;
    * one level of nested mapping under a key, such as `metadata:`, whose
      values are scalars or flow sequences;
    * comments and blank lines.

  Anything else, such as block scalars (`|`, `>`), anchors, aliases, tags,
  flow mappings, multi-line quoted strings, deeper nesting, a comment inside
  a flow sequence, a blank or comment line inside a multi-line plain scalar,
  or a number outside the range of a double, is refused with a
  `Snodo.Skills.Frontmatter.Error` whose reason is `:unsupported`. Each of
  those is valid YAML that the subset would otherwise read differently from a
  full YAML parser. Malformed escapes, such as a signed `\\u+041`, are
  `:invalid`.
  Pass `parser:` to `parse/2`, or `:frontmatter_parser` to `use Snodo.Skills`
  and `Snodo.Skills.Client`, to read full YAML with a library instead.

  A parser is a one-argument function, or a `{module, function}` pair, that
  takes the YAML text between the `---` lines and returns `{:ok, value}` or
  `{:error, reason}`. The value must be a JSON object with string keys, or
  `nil` for an empty block.
  """

  alias Snodo.JSONValue
  alias Snodo.Skills.Frontmatter.Error

  @typedoc "A YAML parser for frontmatter text."
  @type parser :: (String.t() -> {:ok, term()} | {:error, term()}) | {module(), atom()}

  # The block the conformance runner and other hosts match: an opening line
  # of exactly three dashes and the first closing line of three dashes.
  @block ~r/\A---\r?\n(.*?)\r?\n---[ \t]*(?:\r?\n|\z)/s
  @bom "﻿"

  @simple_escapes %{
    "0" => <<0>>,
    "a" => <<7>>,
    "b" => <<8>>,
    "t" => <<9>>,
    "\t" => <<9>>,
    "n" => <<10>>,
    "v" => <<11>>,
    "f" => <<12>>,
    "r" => <<13>>,
    "e" => <<27>>,
    " " => " ",
    "\"" => "\"",
    "/" => "/",
    "\\" => "\\",
    "N" => <<0x85::utf8>>,
    "_" => <<0xA0::utf8>>,
    "L" => <<0x2028::utf8>>,
    "P" => <<0x2029::utf8>>
  }
  @hex_escapes %{"x" => 2, "u" => 4, "U" => 8}

  @doc """
  Splits a SKILL.md file into its frontmatter text and its body.

  A leading byte order mark is ignored. Returns an error with reason
  `:missing` when the file does not begin with a `---` line followed, after
  the frontmatter, by a closing `---` line.
  """
  @spec split(String.t()) :: {:ok, String.t(), String.t()} | {:error, Error.t()}
  def split(text) when is_binary(text) do
    text = strip_bom(text)

    case Regex.run(@block, text, return: :index) do
      [{0, length}, {start, size}] ->
        {:ok, binary_part(text, start, size), binary_part(text, length, byte_size(text) - length)}

      nil ->
        {:error, error(:missing, 1, "SKILL.md does not begin with a --- frontmatter block")}
    end
  end

  @doc """
  Reads the frontmatter of a SKILL.md file as a JSON object.

  Options:

    * `:parser` - a `t:parser/0` to use instead of the built-in subset.
  """
  @spec parse(String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def parse(text, opts \\ []) when is_binary(text) and is_list(opts) do
    with {:ok, yaml, _body} <- split(text),
         {:ok, value} <- run_parser(Keyword.get(opts, :parser), yaml) do
      object(value)
    end
  end

  @doc """
  Decodes frontmatter text, the lines between the `---` delimiters, with the
  built-in subset. Line numbers in errors count the opening `---` as line 1.
  """
  @spec decode(String.t()) :: {:ok, map()} | {:error, Error.t()}
  def decode(yaml) when is_binary(yaml) do
    unless String.valid?(yaml), do: fail(:invalid, nil, "frontmatter is not valid UTF-8")
    {:ok, yaml |> lines() |> top_mapping()}
  catch
    {__MODULE__, %Error{} = error} -> {:error, error}
  end

  @doc false
  @spec validate_parser!(term()) :: parser() | nil
  def validate_parser!(nil), do: nil
  def validate_parser!(parser) when is_function(parser, 1), do: parser

  def validate_parser!({module, function} = parser) when is_atom(module) and is_atom(function),
    do: parser

  def validate_parser!(_parser) do
    raise ArgumentError,
          ":frontmatter_parser must be a one-argument function or a {module, function} pair"
  end

  defp strip_bom(@bom <> text), do: text
  defp strip_bom(text), do: text

  defp run_parser(nil, yaml), do: decode(yaml)

  defp run_parser(parser, yaml) do
    case call_parser(parser, yaml) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, error(:parser, nil, "frontmatter parser: #{inspect(reason)}")}
      other -> {:error, error(:parser, nil, "frontmatter parser returned #{inspect(other)}")}
    end
  rescue
    exception -> {:error, error(:parser, nil, Exception.message(exception))}
  end

  defp call_parser(parser, yaml) when is_function(parser, 1), do: parser.(yaml)
  defp call_parser({module, function}, yaml), do: apply(module, function, [yaml])

  defp object(nil), do: {:ok, %{}}

  defp object(value) when is_map(value) and not is_struct(value) do
    if JSONValue.valid?(value),
      do: {:ok, value},
      else: {:error, error(:not_object, nil, "frontmatter is not a JSON object")}
  end

  defp object(_value), do: {:error, error(:not_object, nil, "frontmatter is not a mapping")}

  # Lines are {file line, indentation, content}; blank and comment lines go.
  defp lines(yaml) do
    yaml
    |> String.split(~r/\r?\n/)
    |> Enum.with_index(2)
    |> Enum.flat_map(fn {line, number} ->
      line = String.trim_trailing(line)
      content = String.trim_leading(line, " ")

      cond do
        content == "" or String.starts_with?(content, "#") -> []
        String.starts_with?(content, "\t") -> fail(:unsupported, number, "tab indentation")
        true -> [{number, byte_size(line) - byte_size(content), content}]
      end
    end)
  end

  defp top_mapping([]), do: %{}

  defp top_mapping([{number, 0, content} | _rest] = lines) do
    if sequence_item?(content), do: fail(:not_object, number, "frontmatter is not a mapping")
    entries(lines, %{})
  end

  defp top_mapping([{number, _indent, _content} | _rest]),
    do: fail(:invalid, number, "the frontmatter mapping must start in the first column")

  defp entries([], acc), do: acc

  defp entries([{number, 0, content} | rest], acc) do
    {key, inline} = key_value(content, number)
    put_new!(acc, key, number)

    {children, rest} =
      Enum.split_while(rest, fn {_number, indent, child} ->
        indent > 0 or (inline == "" and sequence_item?(child))
      end)

    entries(rest, Map.put(acc, key, value(inline, children, number)))
  end

  defp entries([{number, _indent, _content} | _rest], _acc),
    do: fail(:invalid, number, "unexpected indentation")

  defp value(inline, [], number), do: scalar_or_flow(inline, number)

  defp value("", [{_number, _indent, content} | _rest] = children, _number_of_key) do
    if sequence_item?(content), do: sequence(children), else: nested(children)
  end

  defp value(inline, children, number), do: continuation(inline, children, number)

  # A plain scalar may continue on more deeply indented lines; YAML folds the
  # line breaks into single spaces. YAML keeps a newline for an empty line
  # inside the scalar, and a comment line ends it, so a gap in the line numbers
  # (lines/1 dropped a blank or comment line there) is refused rather than
  # folded into a value a YAML parser would read differently.
  defp continuation(inline, children, number) do
    if quoted_or_flow?(inline),
      do: fail(:unsupported, number, "a quoted string or flow sequence spanning lines")

    parts = [{number, inline} | Enum.map(children, fn {n, _indent, c} -> {n, c} end)]

    parts
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [{previous, _}, {n, _}] ->
      if n != previous + 1,
        do: fail(:unsupported, n, "a blank or comment line inside a multi-line plain scalar")
    end)

    last = length(parts) - 1

    parts
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {{n, text}, index} ->
      {plain, comment?} = strip_comment(text)
      if comment? and index != last, do: fail(:invalid, n, "a comment inside a plain scalar")
      plain
    end)
    |> plain(number)
    |> resolve(number)
  end

  defp nested([{_number, child_indent, _content} | _rest] = children) do
    Enum.reduce(children, %{}, fn {n, indent, content}, acc ->
      cond do
        indent > child_indent -> fail(:unsupported, n, "nesting deeper than one level")
        indent < child_indent -> fail(:invalid, n, "inconsistent indentation")
        sequence_item?(content) -> fail(:unsupported, n, "a sequence inside a nested mapping")
        true -> nested_entry(acc, content, n)
      end
    end)
  end

  defp nested_entry(acc, content, number) do
    {key, inline} = key_value(content, number)
    put_new!(acc, key, number)
    Map.put(acc, key, scalar_or_flow(inline, number))
  end

  defp sequence([{_number, item_indent, _content} | _rest] = children) do
    Enum.map(children, fn {n, indent, content} ->
      cond do
        indent != item_indent -> fail(:unsupported, n, "a multi-line or nested sequence item")
        not sequence_item?(content) -> fail(:invalid, n, "expected a sequence item")
        true -> item(content, n)
      end
    end)
  end

  defp item("-", _number), do: nil

  defp item("- " <> rest, number) do
    rest = String.trim_leading(rest)

    cond do
      sequence_item?(rest) ->
        fail(:unsupported, number, "a nested sequence")

      not quoted_or_flow?(rest) and mapping_like?(elem(strip_comment(rest), 0)) ->
        fail(:unsupported, number, "a sequence of mappings")

      true ->
        scalar_or_flow(rest, number)
    end
  end

  defp sequence_item?(content), do: content == "-" or String.starts_with?(content, "- ")

  defp quoted_or_flow?(text), do: String.starts_with?(text, ["\"", "'", "["])

  defp mapping_like?(text), do: String.contains?(text, ": ") or String.ends_with?(text, ":")

  defp put_new!(acc, key, number) do
    if Map.has_key?(acc, key), do: fail(:invalid, number, "duplicate key #{inspect(key)}")
  end

  # Keys

  defp key_value("\"" <> _rest = content, number) do
    {key, rest} = double_quoted(content, number)
    quoted_key_rest(key, rest, number)
  end

  defp key_value("'" <> _rest = content, number) do
    {key, rest} = single_quoted(content, number)
    quoted_key_rest(key, rest, number)
  end

  defp key_value(content, number) do
    if sequence_item?(content), do: fail(:invalid, number, "unexpected sequence item")

    case Regex.run(~r/\A(.+?):(?:[ \t]+(.*))?\z/, content, capture: :all_but_first) do
      [key] -> {plain_key(key, number), ""}
      [key, rest] -> {plain_key(key, number), inline(rest)}
      nil -> fail(:invalid, number, "expected a key: value line")
    end
  end

  defp quoted_key_rest(key, rest, number) do
    case Regex.run(~r/\A[ \t]*:(?:[ \t]+(.*))?\z/, rest, capture: :all_but_first) do
      [] -> {key, ""}
      [rest] -> {key, inline(rest)}
      nil -> fail(:invalid, number, "expected a key: value line")
    end
  end

  defp plain_key(key, number) do
    key = String.trim(key)
    if key == "", do: fail(:invalid, number, "empty key")
    check_plain_start(key, number)
    if String.contains?(key, " #"), do: fail(:invalid, number, "a comment inside a key")
    key
  end

  defp inline(rest) do
    rest = String.trim(rest)
    if String.starts_with?(rest, "#"), do: "", else: rest
  end

  # Values

  defp scalar_or_flow("", _number), do: nil

  defp scalar_or_flow("\"" <> _rest = text, number),
    do: text |> double_quoted(number) |> after_quoted(number)

  defp scalar_or_flow("'" <> _rest = text, number),
    do: text |> single_quoted(number) |> after_quoted(number)

  defp scalar_or_flow("[" <> rest, number), do: flow_sequence(rest, number, [])

  defp scalar_or_flow(text, number) do
    {plain, _comment?} = strip_comment(text)
    plain |> plain(number) |> resolve(number)
  end

  defp after_quoted({value, rest}, number) do
    if String.trim(rest) == "" or Regex.match?(~r/\A[ \t]+#/, rest),
      do: value,
      else: fail(:invalid, number, "unexpected text after a quoted string")
  end

  defp strip_comment(text) do
    case Regex.split(~r/[ \t]#/, text, parts: 2) do
      [plain, _comment] -> {String.trim(plain), true}
      [plain] -> {String.trim(plain), false}
    end
  end

  defp plain(text, number) do
    check_plain_start(text, number)

    if mapping_like?(text),
      do: fail(:invalid, number, "a mapping value is not allowed here"),
      else: text
  end

  defp check_plain_start(text, number) do
    case text do
      "{" <> _ -> fail(:unsupported, number, "a flow mapping")
      "|" <> _ -> fail(:unsupported, number, "a block scalar")
      ">" <> _ -> fail(:unsupported, number, "a block scalar")
      "&" <> _ -> fail(:unsupported, number, "an anchor")
      "*" <> _ -> fail(:unsupported, number, "an alias")
      "!" <> _ -> fail(:unsupported, number, "a tag")
      "? " <> _ -> fail(:unsupported, number, "a complex key")
      _ -> check_reserved_start(text, number)
    end
  end

  defp check_reserved_start(text, number) do
    if text in ["-", "?", ":"] or
         String.starts_with?(text, ["@", "`", "%", "]", "}", ",", ": ", "- "]),
       do:
         fail(:invalid, number, "a plain scalar cannot start with #{inspect(String.first(text))}"),
       else: :ok
  end

  # The YAML 1.2 core schema.
  defp resolve(text, _number) when text in ["", "~", "null", "Null", "NULL"], do: nil
  defp resolve(text, _number) when text in ["true", "True", "TRUE"], do: true
  defp resolve(text, _number) when text in ["false", "False", "FALSE"], do: false

  defp resolve(text, number) do
    cond do
      Regex.match?(~r/\A[-+]?[0-9]+\z/, text) ->
        text |> String.trim_leading("+") |> String.to_integer()

      Regex.match?(~r/\A0o[0-7]+\z/, text) ->
        text |> binary_part(2, byte_size(text) - 2) |> String.to_integer(8)

      Regex.match?(~r/\A0x[0-9a-fA-F]+\z/, text) ->
        text |> binary_part(2, byte_size(text) - 2) |> String.to_integer(16)

      Regex.match?(~r/\A[-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?\z/, text) ->
        float(text, number)

      Regex.match?(~r/\A[-+]?\.(inf|Inf|INF)\z|\A\.(nan|NaN|NAN)\z/, text) ->
        fail(:unsupported, number, "#{text} has no JSON value")

      true ->
        text
    end
  end

  defp float(original, number) do
    text = String.trim_leading(original, "+")

    {sign, digits} =
      case text do
        "-" <> rest -> {"-", rest}
        rest -> {"", rest}
      end

    # Float.parse/1 needs digits on both sides of the point.
    digits =
      digits
      |> then(&if String.starts_with?(&1, "."), do: "0" <> &1, else: &1)
      |> String.replace(~r/\.(?=[eE]|\z)/, ".0")
      |> then(&if String.contains?(&1, "."), do: &1, else: String.replace(&1, ~r/[eE]/, ".0e"))

    # Float.parse/1 returns :error for a value outside the double range, such
    # as 1e9999, which has no JSON number either.
    case Float.parse(sign <> digits) do
      {value, ""} -> value
      _out_of_range -> fail(:unsupported, number, "#{original} is out of range for a JSON number")
    end
  end

  defp flow_sequence(text, number, acc) do
    text = String.trim_leading(text)

    case text do
      "" ->
        fail(:unsupported, number, "a flow sequence spanning lines")

      "]" <> rest ->
        after_quoted({Enum.reverse(acc), rest}, number)

      _ ->
        {item, rest} = flow_item(text, number)
        flow_separator(String.trim_leading(rest), number, [item | acc])
    end
  end

  defp flow_separator("," <> rest, number, acc), do: flow_sequence(rest, number, acc)
  defp flow_separator("]" <> _rest = rest, number, acc), do: flow_sequence(rest, number, acc)

  # A comment ends the line, so the sequence would continue on the next one.
  defp flow_separator("#" <> _rest, number, _acc),
    do: fail(:unsupported, number, "a comment inside a flow sequence")

  defp flow_separator("", number, _acc),
    do: fail(:unsupported, number, "a flow sequence spanning lines")

  defp flow_separator(_rest, number, _acc),
    do: fail(:invalid, number, "expected , or ] in a flow sequence")

  defp flow_item("\"" <> _rest = text, number), do: double_quoted(text, number)
  defp flow_item("'" <> _rest = text, number), do: single_quoted(text, number)
  defp flow_item("[" <> _rest, number), do: fail(:unsupported, number, "a nested flow sequence")
  defp flow_item("," <> _rest, number), do: fail(:invalid, number, "an empty flow sequence entry")

  defp flow_item(text, number) do
    [plain, rest] =
      case Regex.split(~r/(?=[,\]])/, text, parts: 2) do
        [plain, rest] -> [plain, rest]
        [plain] -> [plain, ""]
      end

    if String.starts_with?(plain, "#") or Regex.match?(~r/[ \t]#/, plain),
      do: fail(:unsupported, number, "a comment inside a flow sequence")

    plain = String.trim(plain)
    if mapping_like?(plain), do: fail(:unsupported, number, "a mapping inside a flow sequence")
    {plain |> plain(number) |> resolve(number), rest}
  end

  defp double_quoted("\"" <> rest, number), do: double_quoted(rest, number, [])

  defp double_quoted("", number, _acc),
    do: fail(:unsupported, number, "a quoted string spanning lines")

  defp double_quoted("\"" <> rest, _number, acc),
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp double_quoted("\\" <> rest, number, acc) do
    {char, rest} = escape(rest, number)
    double_quoted(rest, number, [char | acc])
  end

  defp double_quoted(<<char::utf8, rest::binary>>, number, acc),
    do: double_quoted(rest, number, [<<char::utf8>> | acc])

  defp escape(<<letter::binary-size(1), rest::binary>>, number) do
    cond do
      Map.has_key?(@simple_escapes, letter) ->
        {Map.fetch!(@simple_escapes, letter), rest}

      Map.has_key?(@hex_escapes, letter) ->
        hex_escape(rest, Map.fetch!(@hex_escapes, letter), number)

      true ->
        fail(:invalid, number, "unknown escape \\#{letter}")
    end
  end

  defp escape("", number), do: fail(:unsupported, number, "a quoted string spanning lines")

  defp hex_escape(text, digits, number) do
    # Integer.parse/2 accepts a sign, so the digits are checked first.
    with true <- byte_size(text) >= digits,
         {hex, rest} = :erlang.split_binary(text, digits),
         true <- Regex.match?(~r/\A[0-9A-Fa-f]+\z/, hex),
         {code, ""} <- Integer.parse(hex, 16),
         true <- code in 0..0xD7FF or code in 0xE000..0x10FFFF do
      {<<code::utf8>>, rest}
    else
      _invalid -> fail(:invalid, number, "invalid hexadecimal escape")
    end
  end

  defp single_quoted("'" <> rest, number), do: single_quoted(rest, number, [])

  defp single_quoted("", number, _acc),
    do: fail(:unsupported, number, "a quoted string spanning lines")

  defp single_quoted("''" <> rest, number, acc), do: single_quoted(rest, number, ["'" | acc])

  defp single_quoted("'" <> rest, _number, acc),
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp single_quoted(<<char::utf8, rest::binary>>, number, acc),
    do: single_quoted(rest, number, [<<char::utf8>> | acc])

  defp error(reason, line, message), do: %Error{reason: reason, line: line, message: message}

  @spec fail(Error.reason(), pos_integer() | nil, String.t()) :: no_return()
  defp fail(reason, line, message) do
    message = if line, do: "line #{line}: #{message}", else: message
    throw({__MODULE__, error(reason, line, message)})
  end
end
