defmodule Snodo.TraceContextTest do
  use ExUnit.Case, async: true

  alias Snodo.Envelope
  alias Snodo.Protocol.V2025_11_25
  alias Snodo.Protocol.V2026_07_28
  alias Snodo.TraceContext
  alias Snodo.Transport.Context, as: TransportContext
  alias SnodoTest.TestFixtures

  @parent "00-0af7651916cd43dd8448eb211c80319c-00f067aa0ba902b7-01"
  @state "rojo=00f067aa0ba902b7,congo=t61rcWkgMzE"

  test "extracts valid trace fields into request context without changing metadata" do
    metadata =
      TestFixtures.metadata("2026-07-28", %{
        "traceparent" => @parent,
        "tracestate" => @state
      })

    raw = TestFixtures.request(1, "tools/list", %{"_meta" => metadata})
    transport = %TransportContext{transport: :direct}
    {:ok, envelope} = Envelope.decode(raw, transport)
    {:ok, context} = V2026_07_28.build_context(envelope, TestFixtures.runtime())

    assert context.trace_context == %{"traceparent" => @parent, "tracestate" => @state}
    assert TraceContext.client_metadata!(context.trace_context) == context.trace_context
    assert context.metadata == metadata
  end

  test "ignores malformed or absent trace fields" do
    assert TraceContext.from_metadata(%{}) == %{}
    assert TraceContext.from_metadata(%{"tracestate" => @state}) == %{}

    for parent <- [
          "not-a-parent",
          "00-00000000000000000000000000000000-00f067aa0ba902b7-01",
          "00-0af7651916cd43dd8448eb211c80319c-0000000000000000-01",
          String.upcase(@parent),
          String.replace_prefix(@parent, "00-", "ff-"),
          @parent <> "-extra",
          String.duplicate("x", 513)
        ] do
      assert TraceContext.from_metadata(%{"traceparent" => parent, "tracestate" => @state}) ==
               %{}
    end

    for state <- [
          "rojo=a,rojo=b",
          "rojo=bad\nvalue",
          "rojo=bad=value",
          String.duplicate("x", 513)
        ] do
      assert TraceContext.from_metadata(%{"traceparent" => @parent, "tracestate" => state}) ==
               %{"traceparent" => @parent}
    end

    assert TraceContext.from_metadata(%{"traceparent" => @parent}) == %{
             "traceparent" => @parent
           }
  end

  test "accepts the stable fields of a future traceparent version" do
    future = String.replace_prefix(@parent, "00-", "01-") <> "-future field"
    assert TraceContext.from_metadata(%{"traceparent" => future}) == %{"traceparent" => future}

    assert TraceContext.from_metadata(%{"traceparent" => future <> "\nunsafe"}) == %{}
  end

  test "accepts W3C Trace Context Level 2 tracestate keys" do
    state = "1vendor=x,a@b@c=y"

    assert TraceContext.from_metadata(%{"traceparent" => @parent, "tracestate" => state}) ==
             %{"traceparent" => @parent, "tracestate" => state}
  end

  test "initialize-era contexts extract trace fields too" do
    raw =
      TestFixtures.request(1, "tools/list", %{
        "_meta" => %{"traceparent" => @parent, "tracestate" => @state}
      })

    transport = %TransportContext{
      transport: :direct,
      request_headers: %{"mcp-protocol-version" => "2025-11-25"}
    }

    {:ok, envelope} = Envelope.decode(raw, transport)
    runtime = TestFixtures.runtime(protocols: [V2025_11_25])
    {:ok, context} = V2025_11_25.build_context(envelope, runtime)

    assert context.trace_context == %{"traceparent" => @parent, "tracestate" => @state}
    assert context.metadata == %{"traceparent" => @parent, "tracestate" => @state}
  end

  test "rejects invalid client trace options before sending" do
    assert TraceContext.client_metadata!(%{"traceparent" => @parent, "tracestate" => @state}) ==
             %{"traceparent" => @parent, "tracestate" => @state}

    for invalid <- [
          %{},
          %{"tracestate" => @state},
          %{"traceparent" => nil},
          %{"traceparent" => "invalid"},
          %{"traceparent" => @parent, "tracestate" => nil},
          %{"traceparent" => @parent, "tracestate" => "rojo=bad\nvalue"},
          %{"traceparent" => @parent, "other" => "x"}
        ] do
      assert_raise ArgumentError, ~r/:trace_context must/, fn ->
        TraceContext.client_metadata!(invalid)
      end
    end
  end
end
