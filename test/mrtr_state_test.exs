defmodule Snodo.MRTR.StateTest do
  use ExUnit.Case, async: true

  @moduletag mcp_contract: ["mrtr-state-integrity"]

  alias Snodo.Context
  alias Snodo.Error
  alias Snodo.MRTR.State
  alias Snodo.Transport.Context, as: TransportContext

  @secret :binary.copy("s", 32)
  @now 1_800_000_000

  setup do
    context = %Context{
      protocol_version: "2026-07-28",
      protocol: Snodo.Protocol.V2026_07_28,
      transport: %TransportContext{transport: :direct},
      request_id: "first",
      request_method: "tools/call",
      request_params: %{
        "name" => "publish",
        "arguments" => %{"package" => "ecto", "version" => "1.0.0"}
      }
    }

    %{context: context, opts: options()}
  end

  test "round-trips JSON values and remains reusable before expiry", %{
    context: context,
    opts: opts
  } do
    for value <- [nil, true, false, 42, 1.5, "text", [], %{}, %{"step" => [1, nil, true]}] do
      token = State.seal(value, context, opts)
      assert is_binary(token)
      assert State.open(token, context, opts) == {:ok, value}
      assert State.open(token, context, opts) == {:ok, value}
    end
  end

  test "state is signed but not encrypted and bindings disclose no identity", context do
    token = State.seal(%{"step" => "confirm"}, context.context, context.opts)
    ["mrtr1", encoded, _signature] = String.split(token, ".")
    payload = Base.url_decode64!(encoded, padding: false)

    assert payload =~ "confirm"
    refute payload =~ "principal-secret"
    refute payload =~ @secret
    refute payload =~ "ecto"
  end

  test "rejects modified payload, signature, secret and malformed tokens", %{
    context: context,
    opts: opts
  } do
    token = State.seal(%{"step" => 1}, context, opts)
    [prefix, encoded, signature] = String.split(token, ".")
    altered = Base.url_encode64(JSON.encode!([1, @now, @now + 300, "scope", %{}]), padding: false)

    for invalid <- [
          nil,
          7,
          %{},
          "",
          "mrtr2.#{encoded}.#{signature}",
          "#{prefix}.#{altered}.#{signature}",
          "#{prefix}.#{encoded}.#{String.reverse(signature)}",
          "#{token}.extra",
          "mrtr1.!invalid!.!invalid!",
          :binary.copy("x", 16_385),
          <<255>>
        ] do
      assert_invalid(State.open(invalid, context, opts))
    end

    assert_invalid(State.open(token, context, Keyword.put(opts, :secret, :binary.copy("x", 32))))
  end

  test "binds the authenticated principal including deliberate anonymity", %{
    context: context,
    opts: opts
  } do
    token = State.seal(%{}, context, opts)

    assert_invalid(State.open(token, context, Keyword.put(opts, :principal, "different")))
    assert_invalid(State.open(token, context, Keyword.put(opts, :principal, nil)))

    anonymous = Keyword.put(opts, :principal, nil)
    assert {:ok, %{}} = State.open(State.seal(%{}, context, anonymous), context, anonymous)
  end

  test "binds the method and every salient argument", %{context: context, opts: opts} do
    token = State.seal(%{}, context, opts)

    for changed <- [
          %{context | request_method: "prompts/get"},
          %{context | request_params: Map.put(context.request_params, "name", "delete")},
          %{
            context
            | request_params: put_in(context.request_params, ["arguments", "version"], "2.0.0")
          },
          %{context | request_params: Map.put(context.request_params, "extra", true)},
          %{context | request_params: Map.delete(context.request_params, "arguments")}
        ] do
      assert_invalid(State.open(token, changed, opts))
    end
  end

  test "new request IDs, metadata, transport and retry fields do not change the binding",
       context do
    token = State.seal(%{"step" => 2}, context.context, context.opts)

    retry = %{
      context.context
      | request_id: 999,
        metadata: %{"trace" => "new"},
        transport: %TransportContext{transport: :http},
        request_state: token,
        input_responses: %{"confirm" => %{"action" => "accept"}},
        request_params:
          Map.merge(context.context.request_params, %{
            "_meta" => %{"trace" => "new"},
            "requestState" => token,
            "inputResponses" => %{"confirm" => %{"action" => "accept"}}
          })
    }

    assert {:ok, %{"step" => 2}} = State.open(token, retry, context.opts)
  end

  test "only top-level retry fields are ignored", %{context: context, opts: opts} do
    token = State.seal(%{}, context, opts)
    arguments = Map.put(context.request_params["arguments"], "_meta", %{"salient" => true})
    changed = %{context | request_params: Map.put(context.request_params, "arguments", arguments)}

    assert_invalid(State.open(token, changed, opts))
  end

  test "binding ignores map order but retains list order and numeric representation", context do
    params = %{"name" => "publish", "arguments" => %{"a" => [1, 2], "b" => %{"x" => true}}}
    initial = %{context.context | request_params: params}
    token = State.seal(%{}, initial, context.opts)

    reordered =
      Map.new([
        {"arguments", Map.new([{"b", %{"x" => true}}, {"a", [1, 2]}])},
        {"name", "publish"}
      ])

    assert {:ok, %{}} = State.open(token, %{initial | request_params: reordered}, context.opts)

    for value <- [[2, 1], [1.0, 2], ["1", 2]] do
      changed = %{initial | request_params: put_in(params, ["arguments", "a"], value)}
      assert_invalid(State.open(token, changed, context.opts))
    end
  end

  test "expiry is exclusive and neither a new TTL nor a new request extends it", context do
    opts = Keyword.put(context.opts, :ttl, 10)
    token = State.seal(%{}, context.context, opts)

    assert {:ok, %{}} = State.open(token, context.context, options(@now + 9, 10))

    for now <- [@now + 10, @now + 11, @now + 900] do
      assert_invalid(
        State.open(token, %{context.context | request_id: "retry"}, options(now, 900))
      )
    end

    assert_invalid(State.open(token, context.context, options(@now - 1, 10)))
    assert_invalid(State.open(token, context.context, options(@now, 9)))
  end

  test "requires explicit valid application configuration", %{context: context, opts: opts} do
    for invalid <- [
          [],
          Keyword.delete(opts, :principal),
          Keyword.put(opts, :secret, nil),
          Keyword.put(opts, :secret, :binary.copy("x", 31)),
          Keyword.put(opts, :principal, :atom),
          Keyword.put(opts, :ttl, nil),
          Keyword.put(opts, :ttl, 0),
          Keyword.put(opts, :ttl, 901),
          Keyword.put(opts, :ttl, 1.0),
          Keyword.put(opts, :clock, nil),
          Keyword.put(opts, :clock, fn -> -1 end),
          Keyword.put(opts, :clock, fn -> "clock-secret" end),
          Keyword.put(opts, :unknown, true),
          %{}
        ] do
      assert_raise ArgumentError, fn -> State.seal(%{}, context, invalid) end
      assert_raise ArgumentError, fn -> State.open("untrusted", context, invalid) end
    end
  end

  test "authenticated malformed payloads and invalid lifetimes fail closed", context do
    token = State.seal(%{}, context.context, context.opts)
    [_prefix, encoded, _signature] = String.split(token, ".")

    [version, issued, expires, scope, data] =
      encoded |> Base.url_decode64!(padding: false) |> JSON.decode!()

    for payload <- [
          nil,
          %{},
          [2, issued, expires, scope, data],
          [version, nil, expires, scope, data],
          [version, issued, nil, scope, data],
          [version, issued, issued, scope, data],
          [version, issued, issued + 901, scope, data],
          [version, issued + 1, expires, scope, data],
          [version, issued, expires, nil, data],
          [version, issued, expires, scope, data, "extra"]
        ] do
      assert_invalid(
        State.open(sign_json(JSON.encode!(payload)), context.context, options(@now, 900))
      )
    end

    for invalid_json <- ["not json", "{", <<255>>] do
      assert_invalid(State.open(sign_json(invalid_json), context.context, context.opts))
    end
  end

  test "rejects invalid JSON state, invalid request context and oversized state without echoing data",
       context do
    for value <- [:private_atom, %{private_key: "credential"}, self(), <<255>>] do
      error =
        assert_raise ArgumentError, fn -> State.seal(value, context.context, context.opts) end

      refute Exception.message(error) =~ "credential"
      refute Exception.message(error) =~ "private"
    end

    for invalid <- [
          %{context.context | request_method: nil},
          %{context.context | request_method: ""},
          %{context.context | request_params: nil},
          %{context.context | request_params: %{private: "credential"}}
        ] do
      assert_raise ArgumentError, fn -> State.seal(%{}, invalid, context.opts) end
    end

    assert_raise ArgumentError, ~r/16 KiB/, fn ->
      State.seal(:binary.copy("x", 16_384), context.context, context.opts)
    end
  end

  describe "keyring" do
    @current :binary.copy("c", 32)
    @retired :binary.copy("r", 32)

    test "seals with the current key and names it in the token", %{context: context} do
      opts = keyring([{"current", @current}, {"retired", @retired}])
      token = State.seal(%{"step" => 1}, context, opts)

      ["mrtr2", "current", encoded, _signature] = String.split(token, ".")
      assert [2, @now, _expires, _scope, %{"step" => 1}] = decode(encoded)
      assert State.open(token, context, opts) == {:ok, %{"step" => 1}}
    end

    test "opens tokens sealed with a retired key", %{context: context} do
      token = State.seal(%{"step" => 1}, context, keyring([{"retired", @retired}]))

      for keys <- [
            [{"current", @current}, {"retired", @retired}],
            [{"retired", @retired}, {"current", @current}]
          ] do
        assert State.open(token, context, keyring(keys)) == {:ok, %{"step" => 1}}
      end

      assert_invalid(State.open(token, context, keyring([{"current", @current}])))
      assert_invalid(State.open(token, context, keyring([{"retired", @current}])))
    end

    test "follows the documented cluster rotation", %{context: context} do
      start = keyring([{"a", @retired}])
      accept_b = keyring([{"a", @retired}, {"b", @current}])
      seal_b = keyring([{"b", @current}, {"a", @retired}])
      finish = keyring([{"b", @current}])

      # Each step overlaps with the previous one while nodes are redeployed.
      for {old, new} <- [{start, accept_b}, {accept_b, seal_b}, {seal_b, finish}] do
        for {sealer, opener} <- [{old, new}, {new, old}] do
          token = State.seal(%{"step" => 1}, context, sealer)
          assert State.open(token, context, opener) == {:ok, %{"step" => 1}}
        end
      end

      assert_invalid(State.open(State.seal(%{}, context, start), context, finish))
    end

    test "the key identifier is covered by the signature", %{context: context} do
      # Two identifiers for one secret: the MAC still differs by identifier.
      opts = keyring([{"a", @current}, {"b", @current}])
      token = State.seal(%{}, context, opts)
      ["mrtr2", "a", encoded, signature] = String.split(token, ".")

      for invalid <- [
            "mrtr2.b.#{encoded}.#{signature}",
            "mrtr2.unknown.#{encoded}.#{signature}",
            "mrtr2..#{encoded}.#{signature}",
            "mrtr2.#{:binary.copy("a", 33)}.#{encoded}.#{signature}",
            "mrtr2.a.#{encoded}",
            "mrtr2.a.#{encoded}.#{signature}.extra",
            "mrtr1.#{encoded}.#{signature}"
          ] do
        assert_invalid(State.open(invalid, context, opts))
      end
    end

    test "a token's key only verifies the binding it signed", %{context: context} do
      # Payload and scope from key "a", re-signed under key "b".
      token = State.seal(%{}, context, keyring([{"a", @retired}]))
      ["mrtr2", "a", encoded, _signature] = String.split(token, ".")
      forged = sign_identified("b", encoded, @current)

      assert_invalid(State.open(forged, context, keyring([{"b", @current}, {"a", @retired}])))
    end

    test "a token re-signed under another key's identifier is rejected", %{context: context} do
      opts = keyring([{"a", @current}, {"b", @retired}])
      token = State.seal(%{}, context, opts)
      ["mrtr2", "a", encoded, _signature] = String.split(token, ".")

      assert {:ok, %{}} = State.open(sign_identified("a", encoded, @current), context, opts)
      assert_invalid(State.open(sign_identified("b", encoded, @current), context, opts))
    end

    test ":secret rejects signed tokens with malformed identifiers", %{
      context: context,
      opts: opts
    } do
      token = State.seal(%{}, context, keyring([{"a", @secret}]))
      ["mrtr2", "a", encoded, _signature] = String.split(token, ".")

      assert {:ok, %{}} = State.open(sign_identified("a", encoded, @secret), context, opts)

      for key_id <- ["", :binary.copy("a", 33), "a b", "é", "a+b"] do
        assert_invalid(State.open(sign_identified(key_id, encoded, @secret), context, opts))
      end
    end

    test "unidentified and identified tokens open across :secret and :keys", %{
      context: context,
      opts: opts
    } do
      unidentified = State.seal(%{"from" => "secret"}, context, opts)
      identified = State.seal(%{"from" => "keys"}, context, keyring([{"a", @secret}]))

      assert State.open(unidentified, context, keyring([{"b", @current}, {"a", @secret}])) ==
               {:ok, %{"from" => "secret"}}

      assert State.open(identified, context, opts) == {:ok, %{"from" => "keys"}}

      assert_invalid(State.open(unidentified, context, keyring([{"b", @current}])))

      assert_invalid(State.open(identified, context, Keyword.put(opts, :secret, @current)))
    end

    test "payload version must match the token format", %{context: context} do
      opts = keyring([{"a", @secret}])
      token = State.seal(%{}, context, opts)
      ["mrtr2", "a", encoded, _signature] = String.split(token, ".")
      [2 | rest] = decode(encoded)
      downgraded = Base.url_encode64(JSON.encode!([1 | rest]), padding: false)

      assert {:ok, %{}} = State.open(sign_identified("a", encoded, @secret), context, opts)
      assert_invalid(State.open(sign_identified("a", downgraded, @secret), context, opts))
      assert_invalid(State.open(sign_json(JSON.encode!([2 | rest])), context, opts))
    end

    test "validates the keyring", %{context: context} do
      nine = for index <- 1..9, do: {"k#{index}", @current}
      eight = Enum.take(nine, 8)

      assert {:ok, %{}} =
               State.open(State.seal(%{}, context, keyring(eight)), context, keyring(eight))

      for {keys, message} <- [
            {[], ~r/1 to 8/},
            {nine, ~r/1 to 8/},
            {nil, ~r/1 to 8/},
            {%{"a" => @current}, ~r/1 to 8/},
            {[@current], ~r/1 to 8/},
            {[{"a", @current, :extra}], ~r/1 to 8/},
            {[{"a", @current} | :tail], ~r/1 to 8/},
            {[{"", @current}], ~r/identifiers must be 1 to 32/},
            {[{:binary.copy("a", 33), @current}], ~r/identifiers must be 1 to 32/},
            {[{"a.b", @current}], ~r/identifiers must be 1 to 32/},
            {[{"a b", @current}], ~r/identifiers must be 1 to 32/},
            {[{"é", @current}], ~r/identifiers must be 1 to 32/},
            {[{:a, @current}], ~r/identifiers must be 1 to 32/},
            {[{"a", :binary.copy("x", 31)}], ~r/at least 32 bytes/},
            {[{"a", nil}], ~r/at least 32 bytes/},
            {[{"a", @current}, {"a", @retired}], ~r/unique/}
          ] do
        opts = keyring(keys)
        assert_raise ArgumentError, message, fn -> State.seal(%{}, context, opts) end
        assert_raise ArgumentError, message, fn -> State.open("untrusted", context, opts) end
      end

      assert {:ok, %{}} =
               State.open(
                 State.seal(%{}, context, keyring([{:binary.copy("a", 32), @current}])),
                 context,
                 keyring([{:binary.copy("a", 32), @current}])
               )

      for invalid <- [
            Keyword.put(keyring([{"a", @current}]), :secret, @secret),
            Keyword.delete(options(), :secret)
          ] do
        assert_raise ArgumentError, ~r/exactly one of/, fn ->
          State.seal(%{}, context, invalid)
        end
      end
    end
  end

  defp keyring(keys) do
    options() |> Keyword.delete(:secret) |> Keyword.put(:keys, keys)
  end

  defp decode(encoded), do: encoded |> Base.url_decode64!(padding: false) |> JSON.decode!()

  defp sign_identified(key_id, encoded, secret) do
    mac =
      :crypto.mac(:hmac, :sha256, secret, ["snodo-mrtr-token-v2:", key_id, ".", encoded])
      |> Base.url_encode64(padding: false)

    "mrtr2.#{key_id}.#{encoded}.#{mac}"
  end

  defp options(now \\ @now, ttl \\ 300) do
    [secret: @secret, principal: "principal-secret", ttl: ttl, clock: fn -> now end]
  end

  defp sign_json(json) do
    encoded = Base.url_encode64(json, padding: false)

    mac =
      :crypto.mac(:hmac, :sha256, @secret, ["snodo-mrtr-token-v1:", encoded])
      |> Base.url_encode64(padding: false)

    "mrtr1.#{encoded}.#{mac}"
  end

  defp assert_invalid(result) do
    assert {:error,
            %Error{
              code: -32_602,
              message: "Invalid or expired request state",
              data: nil,
              cause: nil
            }} =
             result
  end
end
