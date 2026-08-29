defmodule MCP.Pagination do
  @moduledoc """
  Stateless, protocol-neutral pagination for MCP list operations.

  Routers continue to return complete, deterministically ordered catalogs. The
  server applies this policy after dispatch, issuing opaque cursors scoped to
  the protocol version, list operation, configured page size, and exact catalog
  contents. A catalog change therefore expires outstanding cursors instead of
  risking duplicate or skipped entries.
  """

  alias MCP.Error
  alias MCP.Result

  @cursor_prefix "mcp1."
  @cursor_version 1
  @default_page_size 100
  @max_cursor_bytes 2_048

  @type operation ::
          :tools_list | :prompts_list | :resources_list | :resource_templates_list

  @type t :: %__MODULE__{page_size: pos_integer()}

  defstruct page_size: @default_page_size

  @doc "Builds and validates an immutable pagination policy."
  @spec new(keyword() | t()) :: t()
  def new(%__MODULE__{} = pagination), do: validate!(pagination)

  def new(opts) when is_list(opts) do
    %__MODULE__{page_size: Keyword.get(opts, :page_size, @default_page_size)}
    |> validate!()
  end

  def new(_opts) do
    raise ArgumentError, "pagination requires a keyword list with a positive integer :page_size"
  end

  @doc "Returns one page and attaches a next cursor to result metadata when more entries remain."
  @spec page(Result.t(), String.t(), operation(), map(), t()) ::
          {:ok, Result.t()} | {:error, Error.t()}
  def page(
        %Result{value: values} = result,
        protocol_version,
        operation,
        params,
        %__MODULE__{page_size: page_size}
      )
      when is_list(values) and is_binary(protocol_version) and is_map(params) do
    scope = catalog_scope(protocol_version, operation, page_size, values)

    with {:ok, offset} <- cursor_offset(params, protocol_version, operation, scope, page_size),
         :ok <- validate_offset(offset, length(values)) do
      next_offset = offset + page_size

      metadata =
        if next_offset < length(values) do
          Map.put(
            result.metadata,
            :next_cursor,
            encode_cursor(protocol_version, operation, next_offset, scope)
          )
        else
          Map.delete(result.metadata, :next_cursor)
        end

      {:ok, %{result | value: Enum.slice(values, offset, page_size), metadata: metadata}}
    end
  end

  def page(%Result{}, _protocol_version, _operation, _params, %__MODULE__{}) do
    {:error, Error.internal("List operation returned a non-list result")}
  end

  defp validate!(%__MODULE__{page_size: page_size} = pagination)
       when is_integer(page_size) and page_size > 0,
       do: pagination

  defp validate!(%__MODULE__{}) do
    raise ArgumentError, "pagination requires a positive integer :page_size"
  end

  defp cursor_offset(params, protocol_version, operation, scope, page_size) do
    case Map.fetch(params, "cursor") do
      :error ->
        {:ok, 0}

      {:ok, cursor} when is_binary(cursor) ->
        decode_cursor(cursor, protocol_version, operation, scope, page_size)

      {:ok, _invalid} ->
        {:error, Error.invalid_params("Cursor must be a string")}
    end
  end

  defp decode_cursor(cursor, protocol_version, operation, scope, page_size)
       when byte_size(cursor) <= @max_cursor_bytes do
    expected_method = method(operation)

    with {:ok, encoded} <- strip_prefix(cursor),
         {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, payload} <- decode_json(json),
         [@cursor_version, ^protocol_version, ^expected_method, offset, cursor_scope] <- payload,
         :ok <- validate_scope(cursor_scope, scope),
         true <- is_integer(offset) and offset > 0 and rem(offset, page_size) == 0 do
      {:ok, offset}
    else
      {:error, %Error{} = error} -> {:error, error}
      _invalid -> {:error, invalid_cursor()}
    end
  end

  defp decode_cursor(_cursor, _protocol_version, _operation, _scope, _page_size) do
    {:error, invalid_cursor()}
  end

  defp strip_prefix(@cursor_prefix <> encoded) when encoded != "", do: {:ok, encoded}
  defp strip_prefix(_cursor), do: :error

  defp decode_json(json) do
    case JSON.decode(json) do
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> :error
    end
  end

  defp validate_scope(scope, scope), do: :ok
  defp validate_scope(_cursor_scope, _current_scope), do: {:error, expired_cursor()}

  defp validate_offset(0, _length), do: :ok
  defp validate_offset(offset, length) when offset < length, do: :ok
  defp validate_offset(_offset, _length), do: {:error, expired_cursor()}

  defp encode_cursor(protocol_version, operation, offset, scope) do
    [@cursor_version, protocol_version, method(operation), offset, scope]
    |> JSON.encode!()
    |> Base.url_encode64(padding: false)
    |> then(&(@cursor_prefix <> &1))
  end

  defp catalog_scope(protocol_version, operation, page_size, values) do
    {@cursor_version, protocol_version, operation, page_size, values}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp method(:tools_list), do: "tools/list"
  defp method(:prompts_list), do: "prompts/list"
  defp method(:resources_list), do: "resources/list"
  defp method(:resource_templates_list), do: "resources/templates/list"

  defp invalid_cursor, do: Error.invalid_params("Invalid pagination cursor")
  defp expired_cursor, do: Error.invalid_params("Pagination cursor has expired")
end
