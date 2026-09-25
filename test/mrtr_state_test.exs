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
