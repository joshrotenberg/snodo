defmodule Snodo.Client.Challenge do
  @moduledoc """
  One authentication challenge from a `WWW-Authenticate` response header.

  A 401 or 403 from an MCP server over HTTP carries the challenge that tells
  a client how to authorize (RFC 9110 section 11.6.1, RFC 6750 section 3, and
  the MCP authorization specification):

      WWW-Authenticate: Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource/mcp", scope="mcp:read"
      WWW-Authenticate: Bearer error="insufficient_scope", scope="mcp:write"

  `parse/1` reads every challenge in one header value. `select/1` picks the
  challenge a token provider acts on from a response's headers. The struct
  keeps every parameter in `params`, keyed by lowercase name, and lifts the
  ones the MCP flow reads:

    * `resource_metadata` - the URL of the protected resource metadata
      document (RFC 9728).
    * `scope` - the scopes the server asks for, split on spaces.
    * `error` and `error_description` - the RFC 6750 error, for example
      `"invalid_token"` or `"insufficient_scope"`.

  A header longer than 8 KiB, or one that does not follow the grammar, parses
  as no challenges. A parameter that appears twice keeps its first value. A
  challenge that carries a token68 credential instead of parameters, such as
  `Negotiate abc==`, has empty `params`, and the challenges after it are
  still read.
  """

  @type t :: %__MODULE__{
          scheme: String.t(),
          params: %{optional(String.t()) => String.t()},
          resource_metadata: String.t() | nil,
          scope: [String.t()],
          error: String.t() | nil,
          error_description: String.t() | nil
        }

  @enforce_keys [:scheme]
  defstruct scheme: nil,
            params: %{},
            resource_metadata: nil,
            scope: [],
            error: nil,
            error_description: nil

  @max_bytes 8_192

  @doc """
  Parses one `WWW-Authenticate` header value into its challenges, in order.

  Parameter values may be tokens or quoted strings; a quoted string is
  unescaped. Schemes and parameter names are lowercased. An empty list means
  the header carries no usable challenge.
  """
  @spec parse(String.t()) :: [t()]
  def parse(header) when is_binary(header) and byte_size(header) <= @max_bytes do
    case lex(header, []) do
      {:ok, lexemes} -> lexemes |> challenges([]) |> Enum.map(&build/1)
      :error -> []
    end
  end

  def parse(_header), do: []

  @doc """
  Picks the challenge to act on from a response's `{name, value}` headers.

  Every `www-authenticate` header (compared without case) is parsed. The
  first `Bearer` challenge wins; without one, the first challenge of any
  scheme is returned, so a provider can report that it does not support the
  scheme. `nil` when the response carries no challenge.
  """
  @spec select([{String.t(), String.t()}]) :: t() | nil
  def select(headers) when is_list(headers) do
    challenges =
      for {name, value} <- headers,
          is_binary(name) and is_binary(value),
          String.downcase(name) == "www-authenticate",
          challenge <- parse(value),
          do: challenge

    Enum.find(challenges, List.first(challenges), &(&1.scheme == "bearer"))
  end

  defp build({scheme, params}) do
    %__MODULE__{
      scheme: scheme,
      params: params,
      resource_metadata: Map.get(params, "resource_metadata"),
      scope: params |> Map.get("scope", "") |> String.split(" ", trim: true),
      error: Map.get(params, "error"),
      error_description: Map.get(params, "error_description")
    }
  end

  # A token followed by `=` starts a parameter; any other token starts a
  # challenge. Commas between parameters and challenges are optional here,
  # which accepts every well-formed header and some sloppy ones. Tokens also
  # take `/`, so that a base64 token68 credential lexes as one token.
  defp challenges([], acc), do: Enum.reverse(acc)
  defp challenges([:comma | rest], acc), do: challenges(rest, acc)
  defp challenges([{:token, _name}, :eq | _rest], acc), do: Enum.reverse(acc)

  defp challenges([{:token, scheme} | rest], acc) do
    {params, rest} =
      case token68(rest) do
        {:ok, rest} -> {%{}, rest}
        :error -> params(rest, %{})
      end

    challenges(rest, [{String.downcase(scheme), params} | acc])
  end

  # Anything else is a grammar error; what was parsed so far stands.
  defp challenges(_lexemes, acc), do: Enum.reverse(acc)

  # A token68 credential (RFC 9110 section 11.3), such as `Negotiate abc==`,
  # is one token and its trailing `=` padding, ending the challenge. It is
  # skipped so that a challenge after it is still read.
  defp token68([{:token, _value} | rest]) do
    case Enum.drop_while(rest, &(&1 == :eq)) do
      [] -> {:ok, []}
      [:comma | _rest] = rest -> {:ok, rest}
      _other -> :error
    end
  end

  defp token68(_lexemes), do: :error

  defp params([{:token, name}, :eq, {kind, value} | rest], acc) when kind in [:token, :quoted] do
    name = String.downcase(name)
    params(rest, Map.put_new(acc, name, value))
  end

  defp params([:comma, {:token, _name}, :eq | _rest] = lexemes, acc),
    do: params(tl(lexemes), acc)

  defp params(lexemes, acc), do: {acc, lexemes}

  defp lex(<<>>, acc), do: {:ok, Enum.reverse(acc)}
  defp lex(<<c, rest::binary>>, acc) when c in [?\s, ?\t], do: lex(rest, acc)
  defp lex(<<?,, rest::binary>>, acc), do: lex(rest, [:comma | acc])
  defp lex(<<?=, rest::binary>>, acc), do: lex(rest, [:eq | acc])

  defp lex(<<?", rest::binary>>, acc) do
    with {:ok, value, rest} <- quoted(rest, []) do
      lex(rest, [{:quoted, value} | acc])
    end
  end

  defp lex(<<c, _rest::binary>> = input, acc) when c in ?a..?z or c in ?A..?Z or c in ?0..?9 do
    {token, rest} = token(input, [])
    lex(rest, [{:token, token} | acc])
  end

  defp lex(<<c, _rest::binary>> = input, acc) when c in ~c"!#$%&'*+-./^_`|~" do
    {token, rest} = token(input, [])
    lex(rest, [{:token, token} | acc])
  end

  defp lex(_input, _acc), do: :error

  defp token(<<c, rest::binary>>, acc)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in ~c"!#$%&'*+-./^_`|~",
       do: token(rest, [c | acc])

  defp token(rest, acc), do: {acc |> Enum.reverse() |> List.to_string(), rest}

  defp quoted(<<?", rest::binary>>, acc),
    do: {:ok, acc |> Enum.reverse() |> List.to_string(), rest}

  defp quoted(<<?\\, c, rest::binary>>, acc) when c in [?\t, ?\s] or c in 0x21..0x7E or c >= 0x80,
    do: quoted(rest, [c | acc])

  defp quoted(<<c, rest::binary>>, acc)
       when c in [?\t, ?\s, 0x21] or c in 0x23..0x5B or c in 0x5D..0x7E or c >= 0x80,
       do: quoted(rest, [c | acc])

  defp quoted(_input, _acc), do: :error
end
