defmodule Snodo.Transport.StreamableHTTP.Card do
  @moduledoc false

  alias Snodo.ServerCard
  alias Snodo.Transport.StreamableHTTP
  alias Snodo.Transport.StreamableHTTP.Request
  alias Snodo.Transport.StreamableHTTP.Response

  @cors [
    {"access-control-allow-origin", "*"},
    {"access-control-allow-methods", "GET"},
    {"access-control-allow-headers", "Content-Type, If-None-Match"},
    {"access-control-expose-headers", "ETag"}
  ]

  @allow {"allow", "GET, HEAD, OPTIONS"}

  def configure(nil, _runtime, _path), do: nil
  def configure(false, _runtime, _path), do: nil

  def configure(%{endpoint_url: url} = options, runtime, path) when map_size(options) == 1 do
    body = runtime |> ServerCard.build(url) |> JSON.encode!()
    etag = ~s("#{Base.encode16(:crypto.hash(:sha256, body), case: :lower)}")

    %{
      path: String.trim_trailing(path, "/") <> "/server-card",
      body: body,
      etag: etag
    }
  end

  def configure(_option, _runtime, _path) do
    raise ArgumentError, ":server_card must be false or %{endpoint_url: public_mcp_url}"
  end

  def respond(%Request{} = request, card, opts) do
    case StreamableHTTP.validate_host(request, opts) do
      :ok -> respond_to_method(request, card)
      {:http_error, status, _error, _id} -> %Response{status: status}
    end
  end

  defp respond_to_method(%Request{method: method, headers: request_headers}, card)
       when method in ["GET", "HEAD"] do
    headers = [
      {"content-type", ServerCard.media_type()},
      {"cache-control", "public, max-age=3600"},
      {"etag", card.etag}
      | @cors
    ]

    cond do
      matches_etag?(request_headers, card.etag) ->
        %Response{status: 304, headers: headers}

      method == "HEAD" ->
        length = {"content-length", Integer.to_string(byte_size(card.body))}
        %Response{status: 200, headers: [length | headers]}

      true ->
        %Response{status: 200, headers: headers, body: card.body}
    end
  end

  defp respond_to_method(%Request{method: "OPTIONS"}, _card),
    do: %Response{status: 204, headers: [@allow | @cors]}

  defp respond_to_method(_request, _card), do: %Response{status: 405, headers: [@allow]}

  defp matches_etag?(headers, etag) do
    Enum.any?(headers, fn
      {"if-none-match", value} ->
        Enum.any?(String.split(value, ","), &(String.trim(&1) in ["*", etag, "W/" <> etag]))

      _other ->
        false
    end)
  end
end
