defmodule SnodoTest.OAuthFixtures do
  @moduledoc false

  @issuer "https://auth.example.test"
  @resource "https://mcp.example.test/mcp"

  def issuer, do: @issuer
  def resource, do: @resource

  def rsa_key(kid \\ "rsa-1"), do: with_kid(JOSE.JWK.generate_key({:rsa, 2048}), kid)
  def ec_key(kid \\ "ec-1"), do: with_kid(JOSE.JWK.generate_key({:ec, "P-256"}), kid)
  def ed_key(kid \\ "ed-1"), do: with_kid(JOSE.JWK.generate_key({:okp, :Ed25519}), kid)

  defp with_kid(jwk, nil), do: jwk
  defp with_kid(jwk, kid), do: JOSE.JWK.merge(jwk, %{"kid" => kid})

  def public_map(jwk, extra \\ %{}) do
    {_kty, map} = JOSE.JWK.to_public_map(jwk)
    Map.merge(map, extra)
  end

  def jwks_document(jwks, extra \\ %{}) do
    JSON.encode!(%{"keys" => Enum.map(jwks, &public_map(&1, extra))})
  end

  # jose does not copy the key's kid into the protected header by itself.
  def sign(jwk, alg, claims, header \\ %{}) do
    {_kty, map} = JOSE.JWK.to_map(jwk)
    header = %{"alg" => alg} |> put_kid(map["kid"]) |> Map.merge(header)
    {_alg, token} = jwk |> JOSE.JWT.sign(header, claims) |> JOSE.JWS.compact()
    token
  end

  defp put_kid(header, nil), do: header
  defp put_kid(header, kid), do: Map.put(header, "kid", kid)

  # A nil override removes the claim.
  def claims(overrides \\ %{}) do
    now = System.os_time(:second)

    %{
      "iss" => @issuer,
      "sub" => "user-1",
      "aud" => @resource,
      "exp" => now + 300,
      "iat" => now,
      "scope" => "mcp:read",
      "client_id" => "client-1"
    }
    |> Map.merge(overrides)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end
end

defmodule SnodoTest.OAuthFixtures.StubVerifier do
  @moduledoc false
  @behaviour Snodo.OAuth.ResourceServer.Verifier

  # The options map a token to the result verify/2 returns for it.
  @impl true
  def verify(token, results) when is_map(results) do
    Map.get(results, token, {:error, :unknown_token})
  end
end

defmodule SnodoTest.OAuthFixtures.JWKSEndpoint do
  @moduledoc false
  @behaviour Plug

  alias Plug.Conn

  @impl true
  def init(opts), do: Map.new(opts)

  @impl true
  def call(%Conn{request_path: "/jwks.json"} = conn, %{document: document}) do
    conn
    |> Conn.put_resp_content_type("application/json")
    |> Conn.send_resp(200, document)
  end

  def call(%Conn{request_path: "/large.json"} = conn, _opts) do
    Conn.send_resp(conn, 200, String.duplicate(" ", 4_096))
  end

  def call(%Conn{} = conn, _opts), do: Conn.send_resp(conn, 404, "")
end

defmodule SnodoTest.OAuthFixtures.ReadTool do
  @moduledoc false
  use Snodo.Tool, name: "read_thing"

  @impl true
  def call(_arguments, context) do
    auth = context.auth || %{}

    {:ok,
     Snodo.Result.structured(%{"principal" => auth[:principal], "scopes" => auth[:scopes] || []})}
  end
end

defmodule SnodoTest.OAuthFixtures.WriteTool do
  @moduledoc false
  use Snodo.Tool, name: "write_thing"

  @impl true
  def call(_arguments, _context), do: {:ok, Snodo.Result.text("written")}
end

# The shape of a Bandit endpoint that composes the two plugs with the
# transport, as the README shows.
defmodule SnodoTest.OAuthFixtures.Endpoint do
  @moduledoc false
  @behaviour Plug

  alias Snodo.OAuth.ResourceServer.Bearer
  alias Snodo.OAuth.ResourceServer.Metadata

  @impl true
  def init(opts) do
    {metadata, opts} = Keyword.pop!(opts, :metadata)
    {bearer, opts} = Keyword.pop!(opts, :bearer)

    %{
      metadata: Metadata.init(metadata),
      bearer: Bearer.init(bearer),
      transport: Snodo.Transport.Plug.init(opts)
    }
  end

  @impl true
  def call(conn, plugs) do
    conn
    |> Metadata.call(plugs.metadata)
    |> Bearer.call(plugs.bearer)
    |> Snodo.Transport.Plug.call(plugs.transport)
  end
end

defmodule SnodoTest.OAuthFixtures.Notes do
  @moduledoc false
  use Snodo.Resource, uri: "demo://notes", name: "notes"

  @impl true
  def read(%{"uri" => uri}, _context) do
    {:ok, Snodo.Result.resource_read(Snodo.Resource.text(uri, "notes"))}
  end
end

defmodule SnodoTest.OAuthFixtures.Audit do
  @moduledoc false
  use Snodo.Prompt, name: "audit"

  @impl true
  def render(_arguments, _context) do
    {:ok, Snodo.Result.prompt_get(Snodo.Prompt.message(:user, Snodo.Prompt.text("Audit it.")))}
  end
end
