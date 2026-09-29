defmodule Snodo.OAuth.ResourceServer.JWKSTest do
  use ExUnit.Case, async: true

  alias Snodo.OAuth.ResourceServer.JWKS
  alias SnodoTest.OAuthFixtures, as: Fixtures

  setup_all do
    %{
      rsa: Fixtures.rsa_key("rsa-1"),
      rsa2: Fixtures.rsa_key("rsa-2"),
      ec: Fixtures.ec_key("ec-1")
    }
  end

  describe "static keys" do
    test "accept JWK maps, PEM strings, JOSE structs, and {kid, key} tuples", %{rsa: rsa, ec: ec} do
      {_kty, pem} = rsa |> JOSE.JWK.to_public() |> JOSE.JWK.to_pem()

      jwks =
        start_supervised!(
          {JWKS,
           keys: [
             Fixtures.public_map(ec),
             pem,
             {"pem-kid", pem},
             {"struct-kid", JOSE.JWK.to_public(rsa)}
           ]}
        )

      assert %{static: 4, fetched: 0, fetched?: false, last_error: nil} = JWKS.stats(jwks)

      # A token with a kid matches only that kid.
      assert {:ok, [_ec]} = JWKS.lookup(jwks, "ec-1", "ES256")
      assert {:ok, []} = JWKS.lookup(jwks, "ec-1", "RS256")
      assert {:ok, [_pem]} = JWKS.lookup(jwks, "pem-kid", "RS256")
      assert {:ok, [_struct]} = JWKS.lookup(jwks, "struct-kid", "PS256")
      assert {:ok, []} = JWKS.lookup(jwks, "unknown", "RS256")

      # A token without a kid matches every key of the algorithm's type.
      assert {:ok, rsa_keys} = JWKS.lookup(jwks, nil, "RS256")
      assert length(rsa_keys) == 3
      assert {:ok, [_ec]} = JWKS.lookup(jwks, nil, "ES256")
      assert {:ok, []} = JWKS.lookup(jwks, nil, "HS256")

      # No URL means no fetch to trigger.
      assert :ok = JWKS.refresh(jwks)
    end

    test "a key that declares an alg matches only that algorithm", %{rsa: rsa} do
      jwks = start_supervised!({JWKS, keys: [Fixtures.public_map(rsa, %{"alg" => "RS256"})]})
      assert {:ok, [_key]} = JWKS.lookup(jwks, "rsa-1", "RS256")
      assert {:ok, []} = JWKS.lookup(jwks, "rsa-1", "RS512")
    end

    test "an oct key serves HMAC lookups only when static" do
      oct = JOSE.JWK.from_oct("0123456789abcdef0123456789abcdef")
      jwks = start_supervised!({JWKS, keys: [{"hmac", oct}]})
      assert {:ok, [_key]} = JWKS.lookup(jwks, "hmac", "HS256")
      assert {:ok, []} = JWKS.lookup(jwks, "hmac", "RS256")
    end

    test "invalid options raise", %{rsa: rsa} do
      for bad <- [
            [],
            [keys: ["not a pem"]],
            [keys: [%{"kty" => "bogus"}]],
            [keys: [42]],
            [url: "http://auth.example.test/jwks.json"],
            [url: "not a url"],
            [url: 42],
            [url: "https://auth.example.test/jwks.json", fetch: :nope],
            [url: "https://auth.example.test/jwks.json", ttl_ms: 0],
            [url: "https://auth.example.test/jwks.json", min_refresh_ms: -1],
            [url: "https://auth.example.test/jwks.json", max_keys: 0],
            [keys: [Fixtures.public_map(rsa)], timeout_ms: :infinity]
          ] do
        assert_raise ArgumentError, fn -> JWKS.init(bad) end
      end
    end
  end

  describe "fetched keys" do
    setup %{rsa: rsa, rsa2: rsa2} do
      {:ok, documents} = Agent.start_link(fn -> Fixtures.jwks_document([rsa]) end)
      owner = self()

      fetch = fn url ->
        send(owner, {:fetch, url})
        Agent.get(documents, & &1)
      end

      %{documents: documents, fetch: fetch, rotated: Fixtures.jwks_document([rsa2])}
    end

    test "the first lookup fetches, later ones use the cache", %{fetch: fetch} do
      url = "https://auth.example.test/jwks.json"
      jwks = start_supervised!({JWKS, url: url, fetch: &{:ok, fetch.(&1)}})

      assert JWKS.stats(jwks).fetched? == false
      assert {:ok, [_key]} = JWKS.lookup(jwks, "rsa-1", "RS256")
      assert_received {:fetch, ^url}
      assert %{fetched: 1, fetched?: true, last_error: nil} = JWKS.stats(jwks)

      assert {:ok, [_key]} = JWKS.lookup(jwks, "rsa-1", "RS256")
      refute_received {:fetch, _url}
    end

    test "an unknown kid refreshes the document, at most once per interval",
         %{documents: documents, fetch: fetch, rotated: rotated} do
      jwks =
        start_supervised!(
          {JWKS,
           url: "https://auth.example.test/jwks.json",
           fetch: &{:ok, fetch.(&1)},
           min_refresh_ms: 60_000}
        )

      assert {:ok, [_key]} = JWKS.lookup(jwks, "rsa-1", "RS256")
      assert_received {:fetch, _url}

      # Rotation: the document now holds rsa-2 only, but the interval has not
      # passed, so a miss does not fetch and the old key remains usable.
      Agent.update(documents, fn _old -> rotated end)
      assert {:ok, []} = JWKS.lookup(jwks, "rsa-2", "RS256")
      refute_received {:fetch, _url}
      assert {:ok, [_key]} = JWKS.lookup(jwks, "rsa-1", "RS256")

      # An explicit refresh ignores the interval.
      assert :ok = JWKS.refresh(jwks)
      assert_received {:fetch, _url}
      assert {:ok, [_key]} = JWKS.lookup(jwks, "rsa-2", "RS256")
      assert {:ok, []} = JWKS.lookup(jwks, "rsa-1", "RS256")
      refute_received {:fetch, _url}
    end

    test "with no interval, a miss refreshes immediately",
         %{documents: documents, fetch: fetch, rotated: rotated} do
      jwks =
        start_supervised!(
          {JWKS,
           url: "https://auth.example.test/jwks.json",
           fetch: &{:ok, fetch.(&1)},
           min_refresh_ms: 0}
        )

      assert {:ok, [_key]} = JWKS.lookup(jwks, "rsa-1", "RS256")
      assert_received {:fetch, _url}
      Agent.update(documents, fn _old -> rotated end)
      assert {:ok, [_key]} = JWKS.lookup(jwks, "rsa-2", "RS256")
      assert_received {:fetch, _url}

      # A miss without a kid is not a rotation signal.
      assert {:ok, []} = JWKS.lookup(jwks, nil, "ES256")
      refute_received {:fetch, _url}
    end

    test "an expired document is refreshed before the lookup",
         %{documents: documents, fetch: fetch, rotated: rotated} do
      jwks =
        start_supervised!(
          {JWKS,
           url: "https://auth.example.test/jwks.json",
           fetch: &{:ok, fetch.(&1)},
           ttl_ms: 1,
           min_refresh_ms: 0}
        )

      assert {:ok, [_key]} = JWKS.lookup(jwks, "rsa-1", "RS256")
      assert_received {:fetch, _url}
      Agent.update(documents, fn _old -> rotated end)
      wait_for_clock(2)

      assert {:ok, [_key]} = JWKS.lookup(jwks, nil, "RS256")
      assert_received {:fetch, _url}
      assert {:ok, [_key]} = JWKS.lookup(jwks, "rsa-2", "RS256")
    end

    test "a failed fetch is reported until a document exists, then the stale keys stay in use",
         %{fetch: fetch} do
      {:ok, mode} = Agent.start_link(fn -> :fail end)

      failing = fn url ->
        case Agent.get(mode, & &1) do
          :fail -> {:error, :boom}
          :raise -> raise "fetch exploded"
          :ok -> {:ok, fetch.(url)}
        end
      end

      jwks =
        start_supervised!(
          {JWKS, url: "https://auth.example.test/jwks.json", fetch: failing, min_refresh_ms: 0}
        )

      assert {:error, :boom} = JWKS.lookup(jwks, "rsa-1", "RS256")
      assert {:error, :boom} = JWKS.refresh(jwks)
      assert %{fetched?: false, last_error: :boom} = JWKS.stats(jwks)

      Agent.update(mode, fn _old -> :raise end)
      assert {:error, {:fetch_raised, %RuntimeError{}}} = JWKS.lookup(jwks, "rsa-1", "RS256")

      Agent.update(mode, fn _old -> :ok end)
      assert {:ok, [_key]} = JWKS.lookup(jwks, "rsa-1", "RS256")

      Agent.update(mode, fn _old -> :fail end)
      assert {:ok, []} = JWKS.lookup(jwks, "rsa-2", "RS256")
      assert {:ok, [_key]} = JWKS.lookup(jwks, "rsa-1", "RS256")
      assert %{fetched?: true, last_error: :boom} = JWKS.stats(jwks)
    end

    test "the document is bounded and filtered", %{rsa: rsa, rsa2: rsa2, ec: ec} do
      document =
        JSON.encode!(%{
          "keys" => [
            Fixtures.public_map(rsa, %{"use" => "enc"}),
            %{"kty" => "oct", "kid" => "secret", "k" => "AAAA"},
            %{"kty" => "RSA", "kid" => "broken"},
            "not a key",
            Fixtures.public_map(rsa2, %{"use" => "sig"}),
            Fixtures.public_map(ec),
            Fixtures.public_map(rsa)
          ]
        })

      jwks =
        start_supervised!(
          {JWKS,
           url: "https://auth.example.test/jwks.json",
           fetch: fn _url -> {:ok, document} end,
           max_keys: 2}
        )

      assert {:ok, [_key]} = JWKS.lookup(jwks, "rsa-2", "RS256")
      assert %{fetched: 2} = JWKS.stats(jwks)
      assert {:ok, [_key]} = JWKS.lookup(jwks, "ec-1", "ES256")
      assert {:ok, []} = JWKS.lookup(jwks, "rsa-1", "RS256")
      assert {:ok, []} = JWKS.lookup(jwks, "secret", "HS256")
    end

    test "an invalid document or fetch result is an error" do
      for {result, reason} <- [
            {{:ok, "not json"}, :invalid_document},
            {{:ok, ~s({"keys": {}})}, :invalid_document},
            {{:ok, ~s([])}, :invalid_document},
            {:garbage, {:invalid_fetch_result, :garbage}}
          ] do
        jwks =
          start_supervised!(
            {JWKS, url: "https://auth.example.test/jwks.json", fetch: fn _url -> result end},
            id: make_ref()
          )

        assert {:error, ^reason} = JWKS.lookup(jwks, "rsa-1", "RS256")
      end
    end
  end

  describe "the default fetch" do
    setup %{rsa: rsa} do
      listener =
        start_supervised!(
          {Bandit,
           plug: {SnodoTest.OAuthFixtures.JWKSEndpoint, document: Fixtures.jwks_document([rsa])},
           ip: {127, 0, 0, 1},
           port: 0,
           startup_log: false}
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
      %{base: "http://127.0.0.1:#{port}"}
    end

    test "fetches a document over loopback HTTP", %{base: base} do
      jwks = start_supervised!({JWKS, url: base <> "/jwks.json"})
      assert {:ok, [_key]} = JWKS.lookup(jwks, "rsa-1", "RS256")
      assert %{fetched: 1, fetched?: true} = JWKS.stats(jwks)
    end

    test "reports a non-200 status and an oversized body", %{base: base} do
      missing = start_supervised!({JWKS, url: base <> "/missing.json"}, id: :missing)
      assert {:error, {:http_status, 404}} = JWKS.lookup(missing, "rsa-1", "RS256")

      large =
        start_supervised!({JWKS, url: base <> "/large.json", max_body_bytes: 1_024}, id: :large)

      assert {:error, :body_too_large} = JWKS.lookup(large, "rsa-1", "RS256")
    end

    test "reports a connection failure" do
      # A closed listener: bind, learn the port, close it.
      {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, port} = :inet.port(socket)
      :ok = :gen_tcp.close(socket)

      jwks =
        start_supervised!({JWKS, url: "http://127.0.0.1:#{port}/jwks.json", timeout_ms: 1_000})

      assert {:error, {:http_error, _reason}} = JWKS.lookup(jwks, "rsa-1", "RS256")
    end
  end

  # The TTL is measured on the monotonic clock; waiting for it to advance is
  # deterministic, unlike sleeping for a process.
  defp wait_for_clock(ms) do
    started = System.monotonic_time(:millisecond)
    spin(started + ms)
  end

  defp spin(deadline) do
    if System.monotonic_time(:millisecond) < deadline, do: spin(deadline), else: :ok
  end
end
