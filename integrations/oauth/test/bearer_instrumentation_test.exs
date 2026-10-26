defmodule Snodo.OAuth.ResourceServer.BearerInstrumentationTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Snodo.OAuth.ResourceServer.Bearer
  alias SnodoTest.OAuthFixtures, as: Fixtures
  alias SnodoTest.OAuthFixtures.StubVerifier

  defmodule Sink do
    @moduledoc false
    @behaviour Snodo.Instrumentation

    @impl true
    def handle_event(name, measurements, metadata, pid) do
      send(pid, {:event, name, measurements, metadata})
    end
  end

  defmodule Raiser do
    @moduledoc false
    def verify(_token, _options), do: raise("boom")
  end

  @start [:snodo, :oauth, :verify, :start]
  @stop [:snodo, :oauth, :verify, :stop]
  @exception [:snodo, :oauth, :verify, :exception]

  defp bearer(results, extra \\ []) do
    Bearer.init(
      [
        resource: Fixtures.resource(),
        verifier: {StubVerifier, results},
        instrumentation: {Sink, self()}
      ] ++ extra
    )
  end

  defp call(token, opts) do
    conn = conn(:post, "/mcp")
    conn = if token, do: put_req_header(conn, "authorization", token), else: conn
    Bearer.call(conn, opts)
  end

  defp outcome(token, opts) do
    call(token, opts)
    assert_receive {:event, @start, %{system_time: _}, %{}}
    assert_receive {:event, @stop, %{duration: _}, %{outcome: outcome} = metadata}
    assert Map.keys(metadata) == [:outcome]
    outcome
  end

  test "an admitted request reports :ok" do
    results = %{"good" => {:ok, Fixtures.claims()}}
    assert outcome("Bearer good", bearer(results)) == :ok
  end

  test "each refusal reports a bounded outcome" do
    expired = Fixtures.claims(%{"exp" => System.os_time(:second) - 60})
    no_aud = Fixtures.claims(%{"aud" => "https://other.example.test/"})

    results = %{
      "expired" => {:ok, expired},
      "aud" => {:ok, no_aud},
      "scope" => {:ok, Fixtures.claims(%{"scope" => ""})},
      "iss" => {:error, :wrong_issuer},
      "sig" => {:error, :expired_signature},
      "other" => {:error, {:keys_unavailable, :down}}
    }

    opts = bearer(results, required_scopes: ["mcp:read"])

    assert outcome(nil, opts) == :missing_token
    assert outcome("Basic dXNlcjpwYXNz", opts) == :missing_token
    assert outcome("Bearer not a token", opts) == :invalid_token
    assert outcome("Bearer expired", opts) == :expired
    assert outcome("Bearer aud", opts) == :wrong_audience
    assert outcome("Bearer scope", opts) == :insufficient_scope
    assert outcome("Bearer iss", opts) == :wrong_issuer
    assert outcome("Bearer sig", opts) == :expired
    assert outcome("Bearer other", opts) == :invalid_token
  end

  test "events do not carry the token or claims" do
    results = %{"secrettoken" => {:ok, Fixtures.claims()}}
    call("Bearer secrettoken", bearer(results))
    assert_receive {:event, _name, _measurements, start}
    assert_receive {:event, _name, _measurements, stop}
    refute inspect([start, stop]) =~ "secrettoken"
    refute inspect([start, stop]) =~ "user-1"
  end

  test "a raising verifier emits :exception and still raises" do
    opts =
      Bearer.init(
        resource: Fixtures.resource(),
        verifier: Raiser,
        instrumentation: {Sink, self()}
      )

    assert_raise RuntimeError, fn -> call("Bearer anything", opts) end
    assert_receive {:event, @start, _measurements, _metadata}

    assert_receive {:event, @exception, %{duration: _},
                    %{kind: :error, reason_class: RuntimeError}}
  end

  test "without a sink nothing is emitted" do
    opts = Bearer.init(resource: Fixtures.resource(), verifier: {StubVerifier, %{}})
    assert call(nil, opts).status == 401
    refute_received {:event, _name, _measurements, _metadata}
  end
end
