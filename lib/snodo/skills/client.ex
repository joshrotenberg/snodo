defmodule Snodo.Skills.Client do
  @moduledoc """
  Client functions for the Skills extension (`io.modelcontextprotocol/skills`)
  over a `Snodo.Client`.

  Declare the extension when connecting, so a server that serves skills to
  declaring clients only, as `Snodo.Skills` does, answers:

      {:ok, client} =
        Snodo.Client.connect({:http, url},
          client_capabilities: Snodo.Skills.Client.capabilities()
        )

      {:ok, [entry | _rest]} = Snodo.Skills.Client.list(client)
      {:ok, skill_md} = Snodo.Skills.Client.load(client, entry)

      {:ok, forms} =
        Snodo.Skills.Client.read(client, entry, "skill://pdf-processing/references/FORMS.md")

  `list/2` and `get/3` only fetch entries; neither reads a skill file. A
  host reads files when it needs them: `load/3` reads a skill's SKILL.md
  and `read/4` any file the entry lists.

  ## Verification

  Every read is checked against the entry before the content is returned:

    1. The URI must be listed in the entry's `"resources"`.
    2. The listed size must be at most `:max_file_bytes`, before anything is
       read.
    3. The content's byte length must equal the listed `"size"`.
    4. The SHA-256 digest of the bytes must equal the listed `"digest"`.
    5. For the skill's SKILL.md, the frontmatter is parsed with
       `Snodo.Skills.Frontmatter` and compared field by field with the
       entry's `"frontmatter"`. A field that is missing on one side and
       `null` on the other is the same.

  An entry whose `"resources"` is `"dynamic"` publishes no digests, so steps
  1 to 4 are skipped and only step 5 applies.

  A read that fails a check returns `{:error, %Snodo.Error{}}` with code
  -32000, kind `:extension`, and data `%{"uri" => uri, "reason" => reason}`,
  where `reason` is one of `"not_listed"`, `"too_large"`, `"size_mismatch"`,
  `"digest_mismatch"`, `"frontmatter_unreadable"`, `"frontmatter_mismatch"`
  (data also has `"fields"`), `"missing_content"`, or `"malformed_entry"`.
  The content is not returned, and nothing more is read.

  ## Options

  Each function also takes the options of `Snodo.Client.request/4`, and:

    * `:max_file_bytes` - the largest listed file size `read/4` and `load/3`
      fetch. Defaults to 16,777,216 (16 MiB).
    * `:frontmatter_parser` - a `t:Snodo.Skills.Frontmatter.parser/0` for
      reading SKILL.md frontmatter.
    * `:max_pages` - for `list/2`, the most `skills/list` pages to request.
      Defaults to the client's `:max_pages`. A listing that still has a
      `nextCursor`, or repeats one, returns a -32000 transport error.
  """

  alias Snodo.Client
  alias Snodo.Error
  alias Snodo.Skills
  alias Snodo.Skills.Frontmatter
  alias Snodo.Skills.Skill

  @default_max_file_bytes 16_777_216
  @own_options [:max_file_bytes, :frontmatter_parser, :max_pages]

  @doc "Returns client capabilities that declare the Skills extension."
  @spec capabilities() :: map()
  def capabilities, do: %{"extensions" => %{Skills.id() => %{}}}

  @doc """
  Lists every skill the server serves, following `nextCursor`. Returns the
  skill entries.
  """
  @spec list(Client.t(), keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def list(%Client{} = client, opts \\ []) when is_list(opts) do
    max_pages = Keyword.get(opts, :max_pages, client.max_pages)

    unless is_integer(max_pages) and max_pages > 0 do
      raise ArgumentError, ":max_pages must be a positive integer"
    end

    list_pages(client, nil, max_pages, MapSet.new(), request_options(opts), [])
  end

  @doc "Gets one skill's entry by the URI of its SKILL.md."
  @spec get(Client.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def get(%Client{} = client, uri, opts \\ []) when is_binary(uri) and is_list(opts) do
    case Client.request(client, "skills/get", %{"uri" => uri}, request_options(opts)) do
      {:ok, %{"skill" => %{"uri" => _uri} = entry}} -> {:ok, entry}
      {:ok, result} -> {:error, malformed("skills/get", result)}
      other -> unexpected(other)
    end
  end

  @doc """
  Reads and verifies a skill's SKILL.md, the first step of loading a skill.
  Returns the resource content map the server sent.
  """
  @spec load(Client.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def load(%Client{} = client, %{"uri" => uri} = entry, opts \\ []) when is_binary(uri),
    do: read(client, entry, uri, opts)

  @doc """
  Reads and verifies one file the skill entry lists. Returns the resource
  content map the server sent.
  """
  @spec read(Client.t(), map(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def read(%Client{} = client, entry, uri, opts \\ [])
      when is_map(entry) and is_binary(uri) and is_list(opts) do
    with {:ok, expected} <- expected(entry, uri, max_file_bytes!(opts)) do
      case Client.read_resource(client, uri, request_options(opts)) do
        {:ok, result} -> verify_result(entry, uri, expected, result, opts)
        other -> unexpected(other)
      end
    end
  end

  @doc """
  Verifies a `resources/read` result for `uri` against a skill entry without
  sending anything, as `read/4` does after reading. Returns the content map.
  """
  @spec verify(map(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def verify(entry, uri, result, opts \\ [])
      when is_map(entry) and is_binary(uri) and is_map(result) and is_list(opts) do
    with {:ok, expected} <- expected(entry, uri, max_file_bytes!(opts)) do
      verify_result(entry, uri, expected, result, opts)
    end
  end

  defp list_pages(_client, _cursor, 0, _seen, _opts, _acc) do
    {:error,
     %Error{
       code: -32_000,
       kind: :transport,
       message: "skills/list did not finish within the page limit"
     }}
  end

  defp list_pages(client, cursor, remaining, seen, opts, acc) do
    params = if cursor, do: %{"cursor" => cursor}, else: %{}

    case Client.request(client, "skills/list", params, opts) do
      {:ok, %{"skills" => skills} = result} when is_list(skills) ->
        next_page(client, Map.get(result, "nextCursor"), remaining, seen, opts, [skills | acc])

      {:ok, result} ->
        {:error, malformed("skills/list", result)}

      other ->
        unexpected(other)
    end
  end

  defp next_page(client, next, remaining, seen, opts, acc) when is_binary(next) and next != "" do
    if MapSet.member?(seen, next) do
      {:error, %Error{code: -32_000, kind: :transport, message: "skills/list repeated a cursor"}}
    else
      list_pages(client, next, remaining - 1, MapSet.put(seen, next), opts, acc)
    end
  end

  defp next_page(_client, _next, _remaining, _seen, _opts, acc),
    do: {:ok, acc |> Enum.reverse() |> Enum.concat()}

  defp expected(%{"resources" => "dynamic"}, _uri, _max_bytes), do: {:ok, :dynamic}

  defp expected(%{"resources" => resources}, uri, max_bytes) when is_list(resources) do
    case Enum.find(resources, &match?(%{"uri" => ^uri}, &1)) do
      %{"digest" => digest, "size" => size}
      when is_binary(digest) and is_integer(size) and size > max_bytes ->
        {:error, failure(uri, "too_large", %{"size" => size, "maxFileBytes" => max_bytes})}

      %{"digest" => digest, "size" => size} when is_binary(digest) and is_integer(size) ->
        {:ok, %{digest: digest, size: size}}

      nil ->
        {:error, failure(uri, "not_listed")}

      _malformed ->
        {:error, failure(uri, "malformed_entry")}
    end
  end

  defp expected(_entry, uri, _max_bytes), do: {:error, failure(uri, "malformed_entry")}

  defp verify_result(entry, uri, expected, result, opts) do
    with {:ok, content, bytes} <- content(result, uri),
         :ok <- verify_bytes(uri, expected, bytes),
         :ok <- verify_frontmatter(entry, uri, bytes, opts) do
      {:ok, content}
    end
  end

  defp content(%{"contents" => contents}, uri) when is_list(contents) do
    with %{} = content <- Enum.find(contents, &match?(%{"uri" => ^uri}, &1)),
         {:ok, bytes} <- bytes(content) do
      {:ok, content, bytes}
    else
      _missing -> {:error, failure(uri, "missing_content")}
    end
  end

  defp content(_result, uri), do: {:error, failure(uri, "missing_content")}

  defp bytes(%{"text" => text}) when is_binary(text), do: {:ok, text}
  defp bytes(%{"blob" => blob}) when is_binary(blob), do: Base.decode64(blob)
  defp bytes(_content), do: :error

  defp verify_bytes(_uri, :dynamic, _bytes), do: :ok

  defp verify_bytes(uri, %{size: size, digest: digest}, bytes) do
    actual_digest = Skill.digest(bytes)

    cond do
      byte_size(bytes) != size ->
        {:error,
         failure(uri, "size_mismatch", %{"expected" => size, "actual" => byte_size(bytes)})}

      actual_digest != digest ->
        {:error,
         failure(uri, "digest_mismatch", %{"expected" => digest, "actual" => actual_digest})}

      true ->
        :ok
    end
  end

  defp verify_frontmatter(%{"uri" => uri} = entry, uri, bytes, opts) do
    parser = Frontmatter.validate_parser!(Keyword.get(opts, :frontmatter_parser))
    listed = Map.get(entry, "frontmatter")

    case Frontmatter.parse(bytes, parser: parser) do
      {:ok, parsed} when is_map(listed) ->
        case differing_fields(parsed, listed) do
          [] -> :ok
          fields -> {:error, failure(uri, "frontmatter_mismatch", %{"fields" => fields})}
        end

      {:ok, _parsed} ->
        {:error, failure(uri, "malformed_entry")}

      {:error, error} ->
        {:error, failure(uri, "frontmatter_unreadable", %{"detail" => error.message})}
    end
  end

  defp verify_frontmatter(_entry, _uri, _bytes, _opts), do: :ok

  defp differing_fields(left, right) do
    (Map.keys(left) ++ Map.keys(right))
    |> Enum.uniq()
    |> Enum.reject(&(Map.get(left, &1) == Map.get(right, &1)))
    |> Enum.sort()
  end

  defp failure(uri, reason, details \\ %{}) do
    %Error{
      code: -32_000,
      kind: :extension,
      message: "Skill file failed verification: #{reason}",
      data: Map.merge(%{"uri" => uri, "reason" => reason}, details)
    }
  end

  defp malformed(method, result) do
    %Error{code: -32_000, kind: :transport, message: "Malformed #{method} result", cause: result}
  end

  defp unexpected({:error, %Error{}} = error), do: error

  defp unexpected(other) do
    {:error,
     %Error{code: -32_000, kind: :transport, message: "Unexpected skills response", cause: other}}
  end

  defp max_file_bytes!(opts) do
    case Keyword.get(opts, :max_file_bytes, @default_max_file_bytes) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> raise ArgumentError, ":max_file_bytes must be a positive integer"
    end
  end

  defp request_options(opts), do: Keyword.drop(opts, @own_options)
end
