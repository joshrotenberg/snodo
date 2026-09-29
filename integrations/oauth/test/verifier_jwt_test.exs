defmodule Snodo.OAuth.ResourceServer.Verifier.JWTTest do
  use ExUnit.Case, async: true

  alias Snodo.OAuth.ResourceServer.JWKS
  alias Snodo.OAuth.ResourceServer.Verifier.JWT
  alias SnodoTest.OAuthFixtures, as: Fixtures

  setup_all do
    rsa = Fixtures.rsa_key("rsa-1")
    ec = Fixtures.ec_key("ec-1")
    ed = Fixtures.ed_key("ed-1")
    %{rsa: rsa, ec: ec, ed: ed, keys: [rsa, ec, ed]}
  end

  setup %{keys: keys} do
    jwks = start_supervised!({JWKS, keys: Enum.map(keys, &Fixtures.public_map/1)})
    %{jwks: jwks, options: [keys: jwks, issuer: Fixtures.issuer()]}
  end

  test "verifies RSA, EC, and EdDSA signatures and returns the claims",
       %{rsa: rsa, ec: ec, ed: ed, options: options} do
    claims = Fixtures.claims()

    for {key, alg} <- [{rsa, "RS256"}, {rsa, "PS384"}, {ec, "ES256"}, {ed, "EdDSA"}] do
      assert {:ok, ^claims} = JWT.verify(Fixtures.sign(key, alg, claims), options)
    end
  end

  test "accepts a list of issuers and map options", %{rsa: rsa, jwks: jwks} do
    token = Fixtures.sign(rsa, "RS256", Fixtures.claims())

    assert {:ok, _claims} =
             JWT.verify(token, %{keys: jwks, issuer: ["https://other.test", Fixtures.issuer()]})
  end

  test "refuses a tampered signature or payload", %{rsa: rsa, ec: ec, options: options} do
    [header, payload, signature] =
      String.split(Fixtures.sign(rsa, "RS256", Fixtures.claims()), ".")

    forged_payload =
      Base.url_encode64(JSON.encode!(Fixtures.claims(%{"sub" => "admin"})), padding: false)

    assert {:error, :bad_signature} =
             JWT.verify(Enum.join([header, forged_payload, signature], "."), options)

    other = Fixtures.sign(ec, "ES256", Fixtures.claims())
    [_other_header, _other_payload, other_signature] = String.split(other, ".")

    assert {:error, :bad_signature} =
             JWT.verify(Enum.join([header, payload, other_signature], "."), options)

    # Same kid, different key.
    impostor = Fixtures.rsa_key("rsa-1")

    assert {:error, :bad_signature} =
             JWT.verify(Fixtures.sign(impostor, "RS256", Fixtures.claims()), options)
  end

  test "refuses none, unlisted, and HMAC algorithms", %{rsa: rsa, options: options} do
    claims = Fixtures.claims()

    assert {:error, :unsupported_alg} =
             JWT.verify(
               Fixtures.sign(rsa, "RS256", claims),
               Keyword.put(options, :algs, ["ES256"])
             )

    unsigned = unsigned_token(%{"alg" => "none", "kid" => "rsa-1"}, claims)
    assert {:error, :unsupported_alg} = JWT.verify(unsigned, options)

    assert_raise ArgumentError, fn ->
      JWT.verify(unsigned, Keyword.put(options, :algs, ["none"]))
    end

    assert_raise ArgumentError, fn -> JWT.verify(unsigned, Keyword.put(options, :algs, [])) end

    # Key confusion: an HMAC token keyed with the public RSA key finds no oct
    # key, even when HS256 is allowed.
    {_kty, public} = rsa |> JOSE.JWK.to_public() |> JOSE.JWK.to_pem()
    confused = Fixtures.sign(JOSE.JWK.from_oct(public), "HS256", claims, %{"kid" => "rsa-1"})
    assert {:error, :unsupported_alg} = JWT.verify(confused, options)
    assert {:error, :unknown_key} = JWT.verify(confused, Keyword.put(options, :algs, ["HS256"]))
  end

  test "refuses a token whose key is unknown, after one refresh when a URL is set",
       %{rsa: rsa, ec: ec, options: options} do
    claims = Fixtures.claims()
    unknown = Fixtures.rsa_key("rsa-9")
    assert {:error, :unknown_key} = JWT.verify(Fixtures.sign(unknown, "RS256", claims), options)

    # The kid exists but for a key of another type.
    assert {:error, :unknown_key} =
             JWT.verify(Fixtures.sign(rsa, "RS256", claims, %{"kid" => "ec-1"}), options)

    # A rotated document is fetched when the kid is unknown.
    {:ok, documents} = Agent.start_link(fn -> Fixtures.jwks_document([ec]) end)

    jwks =
      start_supervised!(
        {JWKS,
         url: "https://auth.example.test/jwks.json",
         fetch: fn _url -> {:ok, Agent.get(documents, & &1)} end,
         min_refresh_ms: 0},
        id: :rotating
      )

    rotating = Keyword.put(options, :keys, jwks)
    assert {:error, :unknown_key} = JWT.verify(Fixtures.sign(rsa, "RS256", claims), rotating)
    Agent.update(documents, fn _old -> Fixtures.jwks_document([ec, rsa]) end)
    assert {:ok, ^claims} = JWT.verify(Fixtures.sign(rsa, "RS256", claims), rotating)

    # A token without a kid is tried against every key of its type.
    no_kid = Fixtures.rsa_key(nil)

    assert {:ok, ^claims} =
             JWT.verify(Fixtures.sign(no_kid, "RS256", claims),
               keys: jwks_with([no_kid, ec]),
               issuer: Fixtures.issuer()
             )
  end

  test "reports an unavailable key document", %{rsa: rsa, options: options} do
    jwks =
      start_supervised!(
        {JWKS, url: "https://auth.example.test/jwks.json", fetch: fn _url -> {:error, :down} end},
        id: :down
      )

    token = Fixtures.sign(rsa, "RS256", Fixtures.claims())

    assert {:error, {:keys_unavailable, :down}} =
             JWT.verify(token, Keyword.put(options, :keys, jwks))
  end

  test "requires the configured issuer and an exp claim", %{rsa: rsa, options: options} do
    assert {:error, :wrong_issuer} =
             JWT.verify(
               Fixtures.sign(rsa, "RS256", Fixtures.claims(%{"iss" => "https://evil.test"})),
               options
             )

    assert {:error, :wrong_issuer} =
             JWT.verify(Fixtures.sign(rsa, "RS256", Fixtures.claims(%{"iss" => nil})), options)

    assert {:error, :wrong_issuer} =
             JWT.verify(Fixtures.sign(rsa, "RS256", Fixtures.claims(%{"iss" => 1})), options)

    assert {:error, :missing_exp} =
             JWT.verify(Fixtures.sign(rsa, "RS256", Fixtures.claims(%{"exp" => nil})), options)

    assert {:error, :missing_exp} =
             JWT.verify(Fixtures.sign(rsa, "RS256", Fixtures.claims(%{"exp" => "soon"})), options)

    # Lifetime and audience are the plug's job: the verifier returns them.
    expired = Fixtures.claims(%{"exp" => 1, "aud" => "https://other.test"})
    assert {:ok, ^expired} = JWT.verify(Fixtures.sign(rsa, "RS256", expired), options)
  end

  test "refuses malformed tokens", %{rsa: rsa, options: options} do
    for bad <- [
          "",
          "abc",
          "a.b",
          "a.b.c.d",
          "!!!.b.c",
          Base.url_encode64("not json", padding: false) <> ".b.c",
          Base.url_encode64("[]", padding: false) <> ".b.c",
          unsigned_token(%{"alg" => "RS256", "kid" => 1}, %{}),
          Base.url_encode64(~s({"alg":"RS256","kid":"rsa-1"}), padding: false) <> ".!!!.c",
          Base.url_encode64(~s({"alg":"RS256","kid":"rsa-1"}), padding: false) <> ".b.c",
          String.slice(Fixtures.sign(rsa, "RS256", Fixtures.claims()), 0..-3//1)
        ] do
      assert {:error, reason} = JWT.verify(bad, options)
      assert reason in [:malformed, :bad_signature], "#{inspect(bad)} gave #{inspect(reason)}"
    end
  end

  test "missing or invalid options raise", %{rsa: rsa, jwks: jwks} do
    token = Fixtures.sign(rsa, "RS256", Fixtures.claims())
    assert_raise ArgumentError, fn -> JWT.verify(token, issuer: Fixtures.issuer()) end
    assert_raise ArgumentError, fn -> JWT.verify(token, keys: jwks) end

    assert_raise ArgumentError, fn ->
      JWT.verify(token, keys: jwks, issuer: Fixtures.issuer(), algs: [:rs256])
    end
  end

  defp unsigned_token(header, claims) do
    Enum.map_join([header, claims], ".", &Base.url_encode64(JSON.encode!(&1), padding: false)) <>
      "."
  end

  defp jwks_with(keys) do
    start_supervised!({JWKS, keys: Enum.map(keys, &Fixtures.public_map/1)}, id: make_ref())
  end
end
