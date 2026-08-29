defmodule MCP.Resource.Template do
  @moduledoc """
  An exact matcher for the simple-expansion subset of URI templates.

  This is deliberately not an RFC 6570 implementation. It recognises one
  narrow shape, the one MCP resource templates overwhelmingly use, and refuses
  everything else so an application is never silently given a matcher that is
  almost right:

    * the scheme is a literal;
    * the authority is one literal or one `{variable}`;
    * each path segment is one literal or one `{variable}`;
    * there is no query, fragment, userinfo, or port;
    * no operator (`+ # . / ; ? & =`) or modifier (`* :n`) appears.

  A variable therefore binds exactly one whole segment, which makes matching
  and extraction unambiguous. `MCP.Resource` compiles a template at build time
  and generates `matches?/1` from the result; a template outside the subset
  compiles to `:unsupported`, and its module must implement `matches?/1`
  itself.

  Matched values are percent-decoded. A variable never binds an empty segment.
  """

  @type variables :: %{optional(String.t()) => String.t()}
  @type part :: {:literal, String.t()} | {:variable, String.t()}
  @type t :: %__MODULE__{scheme: String.t(), authority: part(), segments: [part()]}

  @enforce_keys [:scheme, :authority]
  defstruct [:scheme, :authority, segments: []]

  @scheme ~r/^[A-Za-z][A-Za-z0-9+.-]*$/
  @variable ~r/^\{([A-Za-z0-9_.-]+)\}$/

  # A port, userinfo, query, or fragment puts a template outside the subset.
  @reserved ["?", "#", "@", ":"]

  @doc """
  Compiles a URI template, or reports that it is outside the supported subset.

  `URI.new/1` rejects the braces, so the template is parsed textually. Only the
  concrete URIs handed to `match/2` go through `URI.new/1`.
  """
  @spec compile(String.t()) :: {:ok, t()} | :unsupported
  def compile(uri_template) when is_binary(uri_template) do
    with [scheme, rest] <- String.split(uri_template, "://", parts: 2),
         true <- Regex.match?(@scheme, scheme),
         false <- String.contains?(rest, @reserved),
         [authority | segments] <- String.split(rest, "/"),
         {:ok, authority} <- compile_part(authority),
         {:ok, segments} <- compile_segments(segments) do
      {:ok, %__MODULE__{scheme: scheme, authority: authority, segments: segments}}
    else
      _unsupported -> :unsupported
    end
  end

  @doc """
  Matches a concrete URI, returning the bound variables.
  """
  @spec match(t(), String.t()) :: {:ok, variables()} | :error
  def match(%__MODULE__{} = template, uri) when is_binary(uri) do
    with {:ok, parsed} <- URI.new(uri),
         :ok <- validate_uri(parsed, template.scheme),
         segments = split_path(parsed.path),
         true <- length(segments) == length(template.segments),
         {:ok, bound} <- bind(template.authority, parsed.host, %{}) do
      bind_segments(template.segments, segments, bound)
    else
      _no_match -> :error
    end
  end

  @doc "Returns the variable names a compiled template binds, in template order."
  @spec variables(t()) :: [String.t()]
  def variables(%__MODULE__{} = template) do
    for {:variable, name} <- [template.authority | template.segments], do: name
  end

  defp validate_uri(%URI{} = uri, scheme) do
    # URI.new/1 fills in the well-known port for known schemes and leaves nil
    # for the custom schemes resource templates use, so an explicitly given
    # port is the one that differs from the scheme's default.
    if uri.scheme == scheme and is_binary(uri.host) and uri.host != "" and
         is_nil(uri.query) and is_nil(uri.fragment) and is_nil(uri.userinfo) and
         uri.port == URI.default_port(scheme) do
      :ok
    else
      :error
    end
  end

  defp compile_segments(segments) do
    Enum.reduce_while(segments, {:ok, []}, fn segment, {:ok, parts} ->
      case compile_part(segment) do
        {:ok, part} -> {:cont, {:ok, [part | parts]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, Enum.reverse(parts)}
      :error -> :error
    end
  end

  defp compile_part(""), do: :error

  defp compile_part(segment) when is_binary(segment) do
    case Regex.run(@variable, segment, capture: :all_but_first) do
      [name] ->
        {:ok, {:variable, name}}

      nil ->
        # A segment that is only partly an expression, such as "v{version}",
        # or that carries an operator, is outside the subset.
        if String.contains?(segment, ["{", "}"]), do: :error, else: {:ok, {:literal, segment}}
    end
  end

  defp split_path(nil), do: []
  defp split_path(path) when is_binary(path), do: String.split(path, "/", trim: true)

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

  defp bind({:variable, name}, value, bound) do
    decoded = URI.decode(value)

    if decoded == "", do: :error, else: {:ok, Map.put(bound, name, decoded)}
  end
end
