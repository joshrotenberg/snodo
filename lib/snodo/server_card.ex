defmodule Snodo.ServerCard do
  @moduledoc """
  Builds public MCP Server Cards and optional site-wide AI Catalog documents.

  Only use public identity metadata and URLs when publishing these documents.
  """

  alias Snodo.Protocol.Registry
  alias Snodo.Server.Runtime

  @schema "https://static.modelcontextprotocol.io/schemas/v1/server-card.schema.json"
  @media_type "application/mcp-server-card+json"

  @doc "The media type of a hosted MCP Server Card."
  @spec media_type() :: String.t()
  def media_type, do: @media_type

  @doc """
  Builds a v1 Server Card from a runtime and its public Streamable HTTP URL.

  The runtime's name must use the schema's namespace/name format, and its
  description is required. Invalid card metadata raises `ArgumentError`.
  """
  @spec build(Runtime.t(), String.t()) :: map()
  def build(%Runtime{server_info: info, protocol_registry: registry}, endpoint_url) do
    name = info["name"]
    version = info["version"]

    unless length_in?(name, 3..200) and
             Regex.match?(~r/\A[a-zA-Z0-9.-]+\/[a-zA-Z0-9._-]+\z/, name) do
      raise ArgumentError, "Server Card name must use namespace/name format (3 to 200 characters)"
    end

    unless length_in?(version, 0..255) and
             not version_range?(version) do
      raise ArgumentError,
            "Server Card version must be a single version of at most 255 characters"
    end

    validate_text!(info["description"], "description")

    if Map.has_key?(info, "title"), do: validate_text!(info["title"], "title")

    _ =
      if Map.has_key?(info, "websiteUrl"), do: public_http_url!(info["websiteUrl"], "websiteUrl")

    info
    |> Map.take(["name", "version", "description", "title", "websiteUrl", "icons"])
    |> Map.replace_lazy("icons", fn icons -> Enum.map(icons, &public_icon!/1) end)
    |> Map.put("$schema", @schema)
    |> Map.put("remotes", [
      %{
        "type" => "streamable-http",
        "url" => public_http_url!(endpoint_url),
        "supportedProtocolVersions" => Registry.versions(registry)
      }
    ])
  end

  @doc """
  Builds an AI Catalog v1.0 from a list of `{identifier, hosted_card_url}` pairs.

  Serve the result as `application/ai-catalog+json` at your site's
  `/.well-known/ai-catalog.json` route.
  """
  @spec catalog([{String.t(), String.t()}]) :: map()
  def catalog(entries) do
    %{
      "specVersion" => "1.0",
      "entries" =>
        Enum.map(entries, fn
          {identifier, url} when is_binary(identifier) ->
            %{"identifier" => identifier, "type" => @media_type, "url" => public_http_url!(url)}

          _invalid ->
            raise ArgumentError, "AI Catalog entries must be {string_identifier, card_url} tuples"
        end)
    }
  end

  defp version_range?(version) do
    [core | _suffix] = String.split(version, ["-", "+"], parts: 2)

    Regex.match?(~r/\A[~^<>=]|(?:\A|\.)[xX*](?:\.|\z)/, core) or
      Regex.match?(~r/\s+-\s|\|\|/, version)
  end

  defp public_icon!(icon) do
    _ = public_uri!(icon["src"])
    Map.take(icon, ["src", "mimeType", "sizes", "theme"])
  end

  defp validate_text!(text, field) do
    unless length_in?(text, 1..100) do
      raise ArgumentError, "Server Card #{field} must contain 1 to 100 characters"
    end
  end

  defp length_in?(value, range) do
    is_binary(value) and String.valid?(value) and length(String.codepoints(value)) in range
  end

  defp public_http_url!(value, field \\ "URL") do
    case is_binary(value) && URI.new(value) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil}}
      when scheme in ["https", "http"] and is_binary(host) and host != "" ->
        value

      _ ->
        raise ArgumentError,
              "Server Card #{field} must be an absolute HTTP(S) URL without user information, query, or fragment"
    end
  end

  defp public_uri!(value) when is_binary(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: scheme, userinfo: nil} = uri} when is_binary(scheme) -> uri
      _ -> raise ArgumentError, "Server Card URLs must be absolute and omit user information"
    end
  end

  defp public_uri!(_value), do: raise(ArgumentError, "Server Card URL must be a string")
end
