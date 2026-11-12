defmodule Snodo.Skills do
  @moduledoc """
  The Skills extension (SEP-2640, `io.modelcontextprotocol/skills`) for MCP
  `2026-07-28`.

  A skill is a directory with a `SKILL.md` file at its root and any number of
  supporting files. Each file is an MCP resource under
  `skill://<skill-path>/<file>`, where the last segment of the skill path is
  the skill name. The extension adds three methods:

    * `skills/list` - the skills the server serves, one entry per skill with
      its URI, its SKILL.md frontmatter, and a `{"uri", "digest", "size"}`
      object for every file, so a client can verify what it reads.
    * `skills/get` - one skill's entry, by the URI of its SKILL.md.
    * `resources/directory/read` - the direct children of a skill directory.
      Subdirectories carry the MIME type `inode/directory`. The server
      advertises `"directoryRead": true` when this method is enabled.

  ## Defining skills

  `use Snodo.Skills` builds the catalog when the module compiles:

      defmodule MyApp.Skills do
        use Snodo.Skills, directory: "priv/skills"
      end

  `:directory` is searched for `SKILL.md` files at any depth; each one makes
  its directory a skill, whose path is the directory's path relative to
  `:directory`. A relative `:directory` is relative to the working directory
  of the compiler, which under Mix is the project root. Every regular file in
  the skill directory except dotfiles is part of the skill, and the module
  recompiles when one of them changes.

  `:entries` adds skills the application supplies, each a keyword list or map
  with a `:path` and a `:files` map of relative paths to file contents:

      use Snodo.Skills,
        entries: [
          [path: "release-notes", files: %{"SKILL.md" => skill_md, "TEMPLATE.md" => template}]
        ]

  The two options can be combined. The SKILL.md frontmatter is read with
  `Snodo.Skills.Frontmatter` and must have a non-empty `name`, equal to the
  last segment of the skill path, and a non-empty `description`. Digests are
  SHA-256 hashes of each file's bytes, computed when the module compiles.

  Other options:

    * `:directory_read` - serve `resources/directory/read` and advertise
      `"directoryRead": true`. Defaults to `true`.
    * `:page_size` - skills per `skills/list` page. Defaults to 50. A skill
      entry is never split across pages.
    * `:directory_page_size` - children per `resources/directory/read` page.
      Defaults to 100.
    * `:max_skill_files` - files per skill, SKILL.md included. Defaults to
      512.
    * `:max_skill_bytes` - the total size of a skill's files. Defaults to
      16,777,216 (16 MiB).
    * `:frontmatter_parser` - a `t:Snodo.Skills.Frontmatter.parser/0` to read
      full YAML instead of the built-in subset.
    * `:cache` - `[ttl_ms: non_neg_integer, scope: "private" | "public"]`,
      the `ttlMs` and `cacheScope` of the three results. Defaults to
      `ttl_ms: 0, scope: "private"`.

  An invalid skill, such as a missing SKILL.md, a name that breaks the naming
  rules, unreadable frontmatter, or a skill over `:max_skill_files` or
  `:max_skill_bytes`, raises `ArgumentError` and the module does not compile.

  ## Serving skills

  The module is the extension, and `resources/0` returns one generated
  `Snodo.Resource` module per file, which serves the file's bytes through
  `resources/read` and lists it in `resources/list`. A SKILL.md resource takes
  its name and description from the frontmatter. Install the extension,
  register the resources, and advertise both:

      defmodule MyApp.Server do
        use Snodo.Server,
          name: "my-app",
          version: "1.0.0",
          extensions: [MyApp.Skills],
          capabilities: MyApp.Skills.capabilities(%{"tools" => %{}})

        for file <- MyApp.Skills.resources(), do: resource(file)
      end

  `capabilities/1` adds `"resources"` and the extension's declaration to a
  capabilities map.

  ## Negotiation

  Like every `Snodo.Extension`, the three methods are answered only for a
  request whose client declares `io.modelcontextprotocol/skills` in its
  capabilities. A client that does not gets -32021 (missing required client
  capability), with the extension in the error's `requiredCapabilities`. The
  skill files themselves are ordinary resources that any client can read.
  `Snodo.Skills.Client.capabilities/0` returns the declaration for
  `Snodo.Client`.

  ## Errors

  `skills/get` for a URI that is not a served skill's SKILL.md, and
  `resources/directory/read` for a URI that is not a served skill directory,
  answer -32602 with the URI in the error data. An invalid or expired cursor
  answers -32602.
  """

  alias Snodo.Context
  alias Snodo.Error
  alias Snodo.Extension.Method
  alias Snodo.Result
  alias Snodo.Skills.Catalog

  @id "io.modelcontextprotocol/skills"
  @version "2026-07-28"
  @cursor_prefix "skills1."
  @max_cursor_bytes 1_024

  @doc "Returns the extension identifier, `\"io.modelcontextprotocol/skills\"`."
  @spec id() :: String.t()
  def id, do: @id

  @doc false
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour Snodo.Extension

      {catalog, resources} = Snodo.Skills.Catalog.build!(opts, __MODULE__, __ENV__)

      for path <- catalog.external_resources do
        Module.put_attribute(__MODULE__, :external_resource, path)
      end

      @snodo_skills_catalog catalog
      @snodo_skills_resources resources

      @doc "Returns the skills this module serves."
      @spec skills() :: [Snodo.Skills.Skill.t()]
      def skills, do: @snodo_skills_catalog.skills

      @doc "Returns the generated `Snodo.Resource` module of every skill file."
      @spec resources() :: [module()]
      def resources, do: @snodo_skills_resources

      @doc """
      Adds `"resources"` and this extension's declaration under
      `"extensions"` to a server capabilities map.
      """
      @spec capabilities(map()) :: map()
      def capabilities(base \\ %{}) when is_map(base),
        do: Snodo.Skills.capabilities(base, @snodo_skills_catalog.directory_read)

      @doc false
      def __catalog__, do: @snodo_skills_catalog

      @impl Snodo.Extension
      def id, do: Snodo.Skills.id()

      @impl Snodo.Extension
      def methods, do: Snodo.Skills.methods(@snodo_skills_catalog.directory_read)

      @impl Snodo.Extension
      def negotiate(client_settings, server_settings),
        do: Snodo.Skills.negotiate(client_settings, server_settings)

      @impl Snodo.Extension
      def validate_operation(operation, params, context),
        do: Snodo.Skills.validate_operation(operation, params, context)

      @impl Snodo.Extension
      def dispatch(operation, params, context),
        do: Snodo.Skills.dispatch(__catalog__(), operation, params, context)

      @impl Snodo.Extension
      def shape_result(_operation, %Snodo.Result{kind: :raw, value: value}, _context), do: value

      @impl Snodo.Extension
      def shape_error(error, _context), do: Snodo.Error.to_json_rpc(error)

      @impl Snodo.Extension
      def missing_capability_error(_method, _context), do: Snodo.Skills.missing_capability()
    end
  end

  @doc """
  Adds `"resources"` (keeping any settings already there) and the extension's
  declaration to `capabilities`. The declaration is `%{"directoryRead" =>
  true}` when `directory_read?` is true, and `%{}` otherwise.
  """
  @spec capabilities(map(), boolean()) :: map()
  def capabilities(capabilities, directory_read?)
      when is_map(capabilities) and is_boolean(directory_read?) do
    settings = if directory_read?, do: %{"directoryRead" => true}, else: %{}

    capabilities
    |> Map.put_new("resources", %{})
    |> Map.update("extensions", %{@id => settings}, &Map.put(&1, @id, settings))
  end

  @doc false
  @spec methods(boolean()) :: [Method.t()]
  def methods(directory_read?) do
    [
      Method.new!(
        protocol_version: @version,
        name: "skills/list",
        operation: :skills_list,
        params: :optional
      ),
      Method.new!(protocol_version: @version, name: "skills/get", operation: :skills_get)
    ] ++
      if directory_read?,
        do: [
          Method.new!(
            protocol_version: @version,
            name: "resources/directory/read",
            operation: :directory_read
          )
        ],
        else: []
  end

  @doc false
  # The extension defines no client settings and ignores any it is sent.
  @spec negotiate(map(), map()) :: {:ok, map()}
  def negotiate(%{}, %{}), do: {:ok, %{}}

  @doc false
  @spec validate_operation(atom(), map(), Context.t()) :: :ok | {:error, Error.t()}
  def validate_operation(:skills_list, params, %Context{}), do: validate_cursor(params)

  def validate_operation(:skills_get, params, %Context{}), do: validate_uri(params, "skills/get")

  def validate_operation(:directory_read, params, %Context{}) do
    with :ok <- validate_uri(params, "resources/directory/read") do
      validate_cursor(params)
    end
  end

  @doc false
  @spec dispatch(Catalog.t(), atom(), map(), Context.t()) ::
          {:ok, Result.t()} | {:error, Error.t()}
  def dispatch(%Catalog{} = catalog, :skills_list, params, %Context{}) do
    with {:ok, page, next} <-
           page(catalog.entries, params, catalog.page_size, "skills/list", catalog.scope) do
      {:ok, Result.raw(complete(catalog, %{"skills" => page}, next))}
    end
  end

  def dispatch(%Catalog{} = catalog, :skills_get, %{"uri" => uri}, %Context{}) do
    case Map.fetch(catalog.by_uri, uri) do
      {:ok, entry} -> {:ok, Result.raw(complete(catalog, %{"skill" => entry}, nil))}
      :error -> {:error, Error.invalid_params("Unknown skill", %{"uri" => uri})}
    end
  end

  def dispatch(%Catalog{} = catalog, :directory_read, %{"uri" => uri} = params, %Context{}) do
    directory = String.trim_trailing(uri, "/")

    with {:ok, children} <- fetch_directory(catalog, directory, uri),
         {:ok, page, next} <-
           page(
             children,
             params,
             catalog.directory_page_size,
             "resources/directory/read",
             catalog.scope <> directory
           ) do
      {:ok, Result.raw(complete(catalog, %{"resources" => page}, next))}
    end
  end

  @doc false
  @spec missing_capability() :: Error.t()
  def missing_capability do
    %Error{
      code: -32_021,
      message: "Missing required client capability",
      kind: :extension,
      data: %{"requiredCapabilities" => %{"extensions" => %{@id => %{}}}}
    }
  end

  defp fetch_directory(catalog, directory, uri) do
    case Map.fetch(catalog.directories, directory) do
      {:ok, children} -> {:ok, children}
      :error -> {:error, Error.invalid_params("Not a skill directory", %{"uri" => uri})}
    end
  end

  defp complete(catalog, result, next_cursor) do
    result
    |> Map.merge(%{
      "resultType" => "complete",
      "ttlMs" => catalog.cache.ttl_ms,
      "cacheScope" => catalog.cache.scope
    })
    |> then(&if next_cursor, do: Map.put(&1, "nextCursor", next_cursor), else: &1)
  end

  defp validate_uri(params, method) do
    case params do
      %{"uri" => uri} when is_binary(uri) and uri != "" -> :ok
      _missing -> {:error, Error.invalid_params("#{method} requires a uri string")}
    end
  end

  defp validate_cursor(params) do
    case params do
      %{"cursor" => cursor} when not is_binary(cursor) ->
        {:error, Error.invalid_params("Cursor must be a string")}

      _valid ->
        :ok
    end
  end

  # Cursors carry the method, the offset, and a fingerprint of the catalog,
  # so a cursor from another listing or another build is refused.
  defp page(values, params, page_size, method, scope) do
    with {:ok, offset} <- offset(params, method, scope, length(values)) do
      next = offset + page_size
      cursor = if next < length(values), do: encode_cursor(method, next, scope)
      {:ok, Enum.slice(values, offset, page_size), cursor}
    end
  end

  defp offset(%{"cursor" => cursor}, method, scope, count)
       when is_binary(cursor) and byte_size(cursor) <= @max_cursor_bytes do
    with @cursor_prefix <> encoded <- cursor,
         {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, [^method, offset, ^scope]} when is_integer(offset) and offset > 0 <-
           JSON.decode(json),
         true <- offset < count do
      {:ok, offset}
    else
      _invalid -> {:error, Error.invalid_params("Invalid pagination cursor")}
    end
  end

  defp offset(%{"cursor" => _cursor}, _method, _scope, _count),
    do: {:error, Error.invalid_params("Invalid pagination cursor")}

  defp offset(_params, _method, _scope, _count), do: {:ok, 0}

  defp encode_cursor(method, offset, scope) do
    @cursor_prefix <> Base.url_encode64(JSON.encode!([method, offset, scope]), padding: false)
  end
end
