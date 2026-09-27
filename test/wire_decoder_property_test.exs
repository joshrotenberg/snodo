defmodule Snodo.WireDecoderPropertyTest do
  # Property tests for the decoders that take untrusted bytes. Each property
  # holds for any input: the decoder returns a result or an error value and
  # never raises.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Snodo.Envelope
  alias Snodo.Error
  alias Snodo.JSONValue
  alias Snodo.Pagination
  alias Snodo.Result
  alias Snodo.Transport.Context, as: TransportContext
  alias Snodo.Transport.Stdio.Framing
  alias Snodo.Transport.StreamableHTTP.Server, as: HTTPServer
  alias SnodoTest.TestFixtures

  @int64_min -9_223_372_036_854_775_808
  @int64_max 9_223_372_036_854_775_807
  @list_operations [:tools_list, :prompts_list, :resources_list, :resource_templates_list]
  @protocol_versions ["2026-07-28", "2025-11-25", "2025-06-18"]

  describe "Snodo.JSONValue.decode/1" do
    property "returns a result or an error for any bytes" do
      check all(text <- untrusted_json_text()) do
        case JSONValue.decode(text) do
          {:ok, _value} -> :ok
          {:error, _reason} -> :ok
        end
      end
    end

    property "round-trips JSON values whose integers have at most 64 digits" do
      check all(value <- json_value()) do
        assert JSONValue.decode(JSON.encode!(value)) == {:ok, value}
      end
    end

    property "decodes integer literals of at most 64 digits" do
      check all(literal <- integer_literal(1..64)) do
        assert JSONValue.decode(~s({"n":#{literal}})) ==
                 {:ok, %{"n" => String.to_integer(literal)}}
      end
    end

    property "refuses integer literals over 64 digits" do
      check all(literal <- integer_literal(65..400)) do
        assert JSONValue.decode(~s({"n":#{literal}})) == {:error, :integer_too_long}
      end
    end
  end

  describe "Snodo.Transport.Stdio.Framing.decode_line/1" do
    property "returns a message or a parse error for any line" do
      check all(line <- one_of([untrusted_json_text(), iodata_line()])) do
        case Framing.decode_line(line) do
          {:ok, _message} -> :ok
          {:error, %Error{code: -32_700}} -> :ok
        end
      end
    end

    property "decodes every encoded message" do
      check all(
              message <- json_object(),
              prefix <- member_of(["", <<0xEF, 0xBB, 0xBF>>]),
              ending <- member_of(["", "\r"])
            ) do
        [json, "\n"] = Framing.encode_message(message)
        assert Framing.decode_line([prefix, json, ending, "\n"]) == {:ok, message}
      end
    end
  end

  describe "Snodo.Envelope.decode/2" do
    property "returns an envelope with a bounded id or an error for any JSON term" do
      transport = %TransportContext{transport: :direct}

      check all(raw <- one_of([envelope_term(), json_value()])) do
        case Envelope.decode(raw, transport) do
          {:ok, %Envelope{kind: :request, id: id, method: method}} ->
            assert Envelope.bounded_id?(id)
            assert %{"jsonrpc" => "2.0", "id" => ^id, "method" => ^method} = raw

          {:ok, %Envelope{kind: :notification, id: nil, method: method}} ->
            refute Map.has_key?(raw, "id")
            assert %{"jsonrpc" => "2.0", "method" => ^method} = raw

          {:error, %Error{}} ->
            :ok
        end
      end
    end
  end

  describe "the HTTP listener's request head parser" do
    property "returns a request or a 4xx error for any head" do
      check all(head <- request_head(), max_body_bytes <- integer(0..2_000_000)) do
        case HTTPServer.parse_request_head(head, max_body_bytes) do
          {:ok, _method, _target, _headers, length} ->
            assert length in 0..max_body_bytes

          {:error, status, message} ->
            assert status in 400..499
            assert is_binary(message)
        end
      end
    end

    property "answers any head with a 4xx response or a close and keeps serving" do
      opts = [runtime: TestFixtures.runtime(), port: 0, read_timeout: 50]
      {:ok, server} = start_supervised({HTTPServer, opts})
      {_ip, port, _path} = HTTPServer.address(server)

      check all(head <- request_head()) do
        response = exchange(port, head <> "\r\n\r\n")
        assert response == "" or response =~ ~r{\AHTTP/1\.1 4\d\d }
      end

      raw = TestFixtures.request("after-properties", "tools/list")
      assert exchange(port, valid_request(raw)) =~ ~r{\AHTTP/1\.1 200 }
    end
  end

  describe "Snodo.Pagination cursors" do
    property "returns a page or an error for any cursor" do
      check all(
              cursor <- cursor_string(),
              values <- catalog(),
              page_size <- integer(1..4),
              operation <- member_of(@list_operations),
              version <- member_of(@protocol_versions)
            ) do
        result = %Result{kind: :raw, value: values}
        params = %{"cursor" => cursor}

        case Pagination.page(result, version, operation, params, pagination(page_size)) do
          {:ok, %Result{}} -> :ok
          {:error, %Error{}} -> :ok
        end
      end
    end

    property "a cursor is refused for any other catalog, method, version, or page size" do
      check all(
              issued <- listing(),
              presented <- one_of([constant(issued), changed_listing(issued)])
            ) do
        for cursor <- cursors(issued) do
          case {presented == issued, page(presented, cursor)} do
            {true, result} -> assert {:ok, %Result{}} = result
            {false, result} -> assert {:error, %Error{code: -32_602}} = result
          end
        end
      end
    end
  end

  # JSON values. Integers are bounded to 64 digits; floats are finite.

  defp json_value do
    leaf = one_of([constant(nil), boolean(), json_integer(), float(), string(:utf8)])

    tree(leaf, fn child ->
      one_of([
        list_of(child, max_length: 4),
        map_of(string(:utf8, max_length: 8), child, max_length: 4)
      ])
    end)
  end

  defp json_object, do: map_of(string(:utf8, max_length: 8), json_value(), max_length: 4)

  defp json_integer do
    one_of([integer(), map(integer_literal(1..64), &String.to_integer/1)])
  end

  # A JSON integer literal with a digit count in the range, optionally negative.
  defp integer_literal(digit_counts) do
    gen all(
          count <- integer(digit_counts),
          first <- integer(1..9),
          rest <- string(?0..?9, length: count - 1),
          sign <- member_of(["", "-"])
        ) do
      "#{sign}#{first}#{rest}"
    end
  end

  # Arbitrary bytes, plus valid JSON text with bytes spliced in, so that inputs
  # reach past the first byte of the decoder.
  defp untrusted_json_text do
    one_of([
      binary(),
      string(:printable),
      map(json_value(), &JSON.encode!/1),
      bind(json_value(), &spliced(JSON.encode!(&1)))
    ])
  end

  defp spliced(text) do
    gen all(
          at <- integer(0..byte_size(text)),
          drop <- integer(0..4),
          insert <- one_of([binary(max_length: 4), member_of(json_fragments())])
        ) do
      resume = min(at + drop, byte_size(text))
      rest = binary_part(text, resume, byte_size(text) - resume)
      binary_part(text, 0, at) <> insert <> rest
    end
  end

  defp json_fragments do
    ["{", "}", "[", "]", ",", ":", "\"", "\\", "\\u", "\\ud800", "-", "0", "e"] ++
      ["1e999", String.duplicate("9", 65), "\n", "\r", <<0xFF>>] ++
      [<<0xE2, 0x80, 0xA8>>, <<0xEF, 0xBB, 0xBF>>]
  end

  defp iodata_line do
    one_of([
      list_of(binary(), max_length: 4),
      map(json_value(), &[JSON.encode_to_iodata!(&1), "\r\n"])
    ])
  end

  # Decoded JSON terms shaped like JSON-RPC messages, with each member either
  # well-formed or any JSON value.

  defp envelope_term do
    gen all(
          members <-
            optional_map(%{
              "jsonrpc" => one_of([constant("2.0"), json_value()]),
              "method" => one_of([string(:utf8), json_value()]),
              "params" => one_of([json_object(), json_value()]),
              "id" => request_id()
            }),
          extra <- json_object()
        ) do
      Map.merge(extra, members)
    end
  end

  defp request_id do
    one_of([
      integer(),
      integer((@int64_min - 4)..(@int64_min + 4)),
      integer((@int64_max - 4)..(@int64_max + 4)),
      string(:ascii, min_length: 250, max_length: 260),
      string(:utf8, max_length: 100),
      json_value()
    ])
  end

  # HTTP/1.1 request heads, without the final blank line: arbitrary bytes,
  # heads built from plausible parts, and those heads with bytes spliced in.

  defp request_head do
    one_of([binary(), structured_head(), bind(structured_head(), &spliced/1)])
  end

  defp structured_head do
    gen all(
          method <- mostly(["GET", "POST", "post", "DELETE", ""], binary()),
          target <- mostly(["/mcp", "/mcp?x=1", "/other", "*"], binary()),
          version <- member_of(["HTTP/1.1", "HTTP/1.0", "HTTP/2", "http/1.1", ""]),
          space <- member_of([" ", "  ", "\t"]),
          headers <- list_of(header_line(), max_length: 6)
        ) do
      Enum.join([Enum.join([method, target, version], space) | headers], "\r\n")
    end
  end

  defp header_line do
    gen all(
          name <-
            mostly(
              ["Content-Length", "content-length", "Content-Type", "Accept", "Host"],
              binary(max_length: 8)
            ),
          separator <- member_of([": ", ":", " : ", ""]),
          value <-
            one_of([
              map(integer(), &Integer.to_string/1),
              member_of(["", " 0 ", "0x10", "+1", "application/json", "localhost"]),
              integer_literal(20..40),
              binary(max_length: 12)
            ])
        ) do
      name <> separator <> value
    end
  end

  # Usually one of the plausible values, sometimes the noise.
  defp mostly(values, noise), do: frequency([{4, member_of(values)}, {1, noise}])

  defp exchange(port, bytes) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, bytes)
    response = recv_until_closed(socket, "")
    :ok = :gen_tcp.close(socket)
    response
  end

  defp recv_until_closed(socket, acc) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, chunk} -> recv_until_closed(socket, acc <> chunk)
      {:error, :closed} -> acc
      {:error, :econnreset} -> acc
    end
  end

  defp valid_request(raw) do
    body = JSON.encode!(raw)

    Enum.join(
      [
        "POST /mcp HTTP/1.1",
        "Host: 127.0.0.1",
        "Content-Type: application/json",
        "Accept: application/json, text/event-stream",
        "MCP-Protocol-Version: 2026-07-28",
        "Mcp-Method: tools/list",
        "Content-Length: #{byte_size(body)}",
        "",
        body
      ],
      "\r\n"
    )
  end

  # Pagination. A listing is the context a cursor is issued for.

  defp catalog(min_length \\ 0) do
    list_of(string(:alphanumeric, max_length: 6), min_length: min_length, max_length: 12)
  end

  defp listing do
    gen all(
          values <- catalog(4),
          operation <- member_of(@list_operations),
          version <- member_of(@protocol_versions),
          page_size <- integer(1..3)
        ) do
      %{values: values, operation: operation, version: version, page_size: page_size}
    end
  end

  defp changed_listing(listing) do
    one_of([
      map(catalog(), &%{listing | values: &1}),
      map(member_of(@list_operations), &%{listing | operation: &1}),
      map(member_of(@protocol_versions), &%{listing | version: &1}),
      map(integer(1..3), &%{listing | page_size: &1})
    ])
  end

  # Every cursor the listing issues, following next cursors from the first page.
  defp cursors(listing), do: cursors(listing, nil, [])

  defp cursors(listing, cursor, issued) do
    {:ok, %Result{metadata: metadata}} = page(listing, cursor)

    case metadata do
      %{next_cursor: next} -> cursors(listing, next, [next | issued])
      _last_page -> Enum.reverse(issued)
    end
  end

  defp page(listing, cursor) do
    params = if cursor, do: %{"cursor" => cursor}, else: %{}

    Pagination.page(
      %Result{kind: :raw, value: listing.values},
      listing.version,
      listing.operation,
      params,
      pagination(listing.page_size)
    )
  end

  defp pagination(page_size), do: Pagination.new(page_size: page_size)

  # Arbitrary strings, and strings that pass the prefix and base64 checks and
  # carry arbitrary JSON or a cursor-shaped array with arbitrary members.
  defp cursor_string do
    payload =
      one_of([
        binary(),
        map(json_value(), &JSON.encode!/1),
        map(
          fixed_list([
            one_of([constant(1), json_value()]),
            one_of([member_of(@protocol_versions), json_value()]),
            one_of([member_of(["tools/list", "prompts/list"]), json_value()]),
            one_of([integer(), json_value()]),
            one_of([string(:alphanumeric, length: 43), json_value()])
          ]),
          &JSON.encode!/1
        )
      ])

    one_of([
      binary(),
      string(:printable),
      map(payload, &("mcp1." <> Base.url_encode64(&1, padding: false))),
      map(payload, &("mcp1." <> Base.url_encode64(&1)))
    ])
  end
end
