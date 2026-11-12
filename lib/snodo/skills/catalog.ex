defmodule Snodo.Skills.Catalog do
  @moduledoc false
  # Builds the catalog `use Snodo.Skills` serves, at compile time: reads the
  # skills, checks them against the limits, computes digests, and generates
  # one Snodo.Resource module per file. The catalog keeps no file contents;
  # those live only in the generated resource modules.

  alias Snodo.Resource
  alias Snodo.Resource.Definition
  alias Snodo.Skills.Frontmatter
  alias Snodo.Skills.Skill
  alias Snodo.Transport.Stdio.Framing

  @default_max_skill_files 512
  @default_max_skill_bytes 16_777_216
  @default_page_size 50
  @default_directory_page_size 100
  # The default Snodo.Client accepts responses up to 16 MiB over HTTP
  # (:max_response_bytes) and stdio (:max_line_bytes).
  @default_max_response_bytes 16_777_216
  # Left for the JSON-RPC envelope and request id, the result's other fields,
  # a cursor, SSE framing, and on resources/read the _meta carrying the whole
  # server_info. Snodo.Envelope bounds the id (256-byte strings, int64), so
  # all but server_info take at most 1,688 + d bytes on resources/read and
  # 1,710 + d on the extension results, d being the digits of ttlMs, which
  # is not bounded; nothing here can check server_info, so the guarantee is
  # conditional on it, as guides/transports.md says.
  @envelope_bytes 4_096
  # The "[" and "]" around the elements of the array the skills part of a
  # response is measured as.
  @array_bytes 2
  @directory_mime_type "inode/directory"

  # The Agent Skills naming rules for the last segment, and an RFC 3986
  # reg-name subset for the segments before it.
  @name ~r/\A(?!.*--)[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?\z/
  @segment ~r/\A[A-Za-z0-9._~-]+\z/

  @options [
    :directory,
    :entries,
    :directory_read,
    :page_size,
    :directory_page_size,
    :max_skill_files,
    :max_skill_bytes,
    :max_response_bytes,
    :frontmatter_parser,
    :cache
  ]

  @mime_types %{
    ".md" => "text/markdown",
    ".markdown" => "text/markdown",
    ".txt" => "text/plain",
    ".json" => "application/json",
    ".yaml" => "application/yaml",
    ".yml" => "application/yaml",
    ".html" => "text/html",
    ".css" => "text/css",
    ".csv" => "text/csv",
    ".xml" => "application/xml",
    ".js" => "text/javascript",
    ".py" => "text/x-python",
    ".sh" => "application/x-sh",
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".svg" => "image/svg+xml",
    ".pdf" => "application/pdf"
  }

  @type t :: %__MODULE__{
          skills: [Skill.t()],
          entries: [map()],
          entry_bytes: [pos_integer()],
          response_budget: pos_integer(),
          by_uri: %{optional(String.t()) => map()},
          directories: %{optional(String.t()) => [map()]},
          directory_bytes: %{optional(String.t()) => [pos_integer()]},
          directory_read: boolean(),
          page_size: pos_integer(),
          directory_page_size: pos_integer(),
          cache: %{ttl_ms: non_neg_integer(), scope: String.t()},
          scope: String.t(),
          external_resources: [String.t()],
          directory: String.t() | nil,
          fingerprint: binary() | nil
        }

  defstruct skills: [],
            entries: [],
            entry_bytes: [],
            response_budget: @default_max_response_bytes - @envelope_bytes,
            by_uri: %{},
            directories: %{},
            directory_bytes: %{},
            directory_read: true,
            page_size: @default_page_size,
            directory_page_size: @default_directory_page_size,
            cache: %{ttl_ms: 0, scope: "private"},
            scope: "",
            external_resources: [],
            directory: nil,
            fingerprint: nil

  @doc false
  @spec build!(keyword(), module(), Macro.Env.t()) :: {t(), [module()]}
  def build!(opts, module, %Macro.Env{} = env) when is_list(opts) do
    validate_options!(opts)
    parser = Frontmatter.validate_parser!(Keyword.get(opts, :frontmatter_parser))

    # Taken before the walk, so a change made while the catalog is built
    # leaves a fingerprint that no longer matches, and the next compile
    # rebuilds it.
    root =
      with directory when is_binary(directory) <- Keyword.get(opts, :directory),
           do: Path.expand(directory)

    fingerprint = if is_binary(root), do: fingerprint(root)

    limits = %{
      files: positive!(opts, :max_skill_files, @default_max_skill_files),
      bytes: positive!(opts, :max_skill_bytes, @default_max_skill_bytes)
    }

    max_response_bytes = max_response_bytes!(opts)
    budget = max_response_bytes - @envelope_bytes

    sources =
      directory_sources(Keyword.get(opts, :directory), limits) ++
        entry_sources(Keyword.get(opts, :entries, []))

    skills =
      sources
      |> Enum.map(&skill!(&1, parser, limits))
      |> Enum.sort_by(& &1.path)
      |> reject_overlapping_paths!()

    directory_read = boolean!(opts, :directory_read, true)

    # Checked before any resource module is generated.
    entry_bytes = check_responses!(skills, max_response_bytes, budget)
    directories = skills |> Enum.map(&directories/1) |> Enum.reduce(%{}, &Map.merge/2)

    directory_bytes =
      check_directories!(directories, directory_read, max_response_bytes, budget)

    {skills, resources} = define_resources!(skills, module, env)
    entries = Enum.map(skills, &Skill.entry/1)

    catalog = %__MODULE__{
      skills: skills,
      entries: entries,
      entry_bytes: entry_bytes,
      response_budget: budget,
      by_uri: Map.new(entries, &{&1["uri"], &1}),
      directories: directories,
      directory_bytes: directory_bytes,
      directory_read: directory_read,
      page_size: positive!(opts, :page_size, @default_page_size),
      directory_page_size: positive!(opts, :directory_page_size, @default_directory_page_size),
      cache: cache!(Keyword.get(opts, :cache, [])),
      scope: scope(entries),
      external_resources: Enum.flat_map(sources, & &1.external),
      directory: if(is_binary(root), do: root),
      fingerprint: fingerprint
    }

    {catalog, resources}
  end

  @doc false
  # A hash of every path under `root` (dotfiles skipped, as the catalog skips
  # them), with its type, size, and modification time. @external_resource
  # only covers the files present at compile time; comparing this hash in
  # __mix_recompile__?/0 also catches a file added or removed. It never
  # raises: an unreadable entry is hashed as its error. Contents are not
  # hashed, to keep the check cheap on every compile, so a same-size edit
  # within the same whole second of mtime goes unnoticed here (documented).
  @spec fingerprint(String.t()) :: binary()
  def fingerprint(root) when is_binary(root) do
    :crypto.hash(:sha256, :erlang.term_to_binary(listing(root), [:deterministic]))
  end

  defp listing(directory) do
    case File.ls(directory) do
      {:ok, names} ->
        names
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.sort()
        |> Enum.map(&listing_entry(directory, &1))

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp listing_entry(directory, name) do
    path = Path.join(directory, name)

    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :directory}} -> {name, :directory, listing(path)}
      {:ok, %File.Stat{type: type, size: size, mtime: mtime}} -> {name, type, size, mtime}
      {:error, reason} -> {name, :error, reason}
    end
  end

  defp validate_options!(opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "use Snodo.Skills expects a keyword list"
    end

    case Keyword.keys(opts) -- @options do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown Snodo.Skills options: #{inspect(unknown)}"
    end

    unless Keyword.has_key?(opts, :directory) or Keyword.has_key?(opts, :entries) do
      raise ArgumentError, "use Snodo.Skills needs a :directory, :entries, or both"
    end
  end

  defp positive!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> raise ArgumentError, "#{inspect(key)} must be a positive integer"
    end
  end

  defp max_response_bytes!(opts) do
    # The smallest skills part of a response is the empty array, "[]", which
    # skills/list sends for an empty catalog, so the budget must hold it.
    minimum = @envelope_bytes + @array_bytes

    case Keyword.get(opts, :max_response_bytes, @default_max_response_bytes) do
      value when is_integer(value) and value >= minimum ->
        value

      _invalid ->
        raise ArgumentError, ":max_response_bytes must be an integer of at least #{minimum}"
    end
  end

  # The skills part of every response the module sends must fit a client
  # limit of :max_response_bytes on HTTP and on stdio (see encoded_size/1),
  # with @envelope_bytes assumed to cover the rest, server_info included.
  # The skills part is measured as a JSON array, brackets included: the
  # "contents" array of a resources/read result, which holds one file, and
  # the page arrays of skills/list and resources/directory/read. So a file's
  # content, a skill entry, or a directory child must take at most the
  # budget less @array_bytes, which also lets it be a page on its own. A
  # skills/get entry is sent without brackets and is checked the same way,
  # since the same entry is a skills/list page element. Pages are cut to the
  # budget when they are served. Returns the encoded size of each entry, in
  # order, for that paging.
  defp check_responses!(skills, max_response_bytes, budget) do
    Enum.map(skills, fn skill ->
      Enum.each(skill.files, &check_file_response!(skill, &1, max_response_bytes, budget))
      size = skill |> Skill.entry() |> encoded_size()

      if size + @array_bytes > budget do
        raise ArgumentError,
              "#{skill.path}: the skill's entry is #{size} bytes, " <>
                over_budget_message(max_response_bytes)
      end

      size
    end)
  end

  defp over_budget_message(max_response_bytes) do
    "more than :max_response_bytes (#{max_response_bytes}) less #{@envelope_bytes} bytes " <>
      "for the envelope and #{@array_bytes} for the brackets of the array it is sent in"
  end

  # A directory child carries the URI and the basename, so a long name can
  # make it larger than any file response or entry, which were checked
  # above. Each child must fit a page on its own, so that every page holds
  # at least one child and paging always advances. Returns the children's
  # sizes, in order, per directory URI, for the paging. Without
  # resources/directory/read no listing is sent, so nothing is refused.
  defp check_directories!(directories, directory_read, max_response_bytes, budget) do
    Map.new(directories, fn {uri, children} ->
      sizes = Enum.map(children, &encoded_size/1)

      if directory_read do
        children
        |> Enum.zip(sizes)
        |> Enum.each(&check_directory_child!(&1, uri, max_response_bytes, budget))
      end

      {uri, sizes}
    end)
  end

  defp check_directory_child!({child, size}, uri, max_response_bytes, budget) do
    if size + @array_bytes > budget do
      raise ArgumentError,
            "#{child["uri"]}: its resources/directory/read entry in #{uri} is #{size} bytes, " <>
              over_budget_message(max_response_bytes)
    end
  end

  defp check_file_response!(skill, file, max_response_bytes, budget) do
    size = file |> content_map() |> encoded_size()

    if size + @array_bytes > budget do
      raise ArgumentError,
            "#{skill.path}/#{file.path}: resources/read would send #{size} bytes of content, " <>
              over_budget_message(max_response_bytes)
    end
  end

  @doc false
  # The bytes a JSON object takes on the larger of the two wire encodings:
  # HTTP sends JSON.encode!/1 output, raw UTF-8; the stdio framing escapes
  # every character outside ASCII as \uXXXX (a surrogate pair above U+FFFF),
  # so "é" takes 6 bytes instead of 2 there. The stdio size is measured with
  # the framing itself, less its newline. Both escape character by character,
  # so the size of a JSON array is the sum of its elements' sizes plus the
  # commas and brackets.
  @spec encoded_size(map()) :: non_neg_integer()
  def encoded_size(value) when is_map(value) do
    http = value |> JSON.encode_to_iodata!() |> IO.iodata_length()
    stdio = (value |> Framing.encode_message() |> IO.iodata_length()) - 1
    max(http, stdio)
  end

  # The resources/read content of one file: text when the bytes are UTF-8,
  # a base64 blob otherwise.
  defp content_map(file) do
    if String.valid?(file.content),
      do: Resource.text(file.uri, file.content, mime_type: file.mime_type),
      else: Resource.blob(file.uri, Base.encode64(file.content), mime_type: file.mime_type)
  end

  defp boolean!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_boolean(value) -> value
      _invalid -> raise ArgumentError, "#{inspect(key)} must be a boolean"
    end
  end

  defp cache!(opts) when is_list(opts) do
    case {Keyword.get(opts, :ttl_ms, 0), Keyword.get(opts, :scope, "private")} do
      {ttl, scope} when is_integer(ttl) and ttl >= 0 and scope in ["private", "public"] ->
        %{ttl_ms: ttl, scope: scope}

      _invalid ->
        raise ArgumentError,
              ":cache takes a non-negative :ttl_ms and a \"private\" or \"public\" :scope"
    end
  end

  defp cache!(_opts), do: raise(ArgumentError, ":cache must be a keyword list")

  # Sources: %{path, files: [{relative path, bytes}], origin, external}.

  defp directory_sources(nil, _limits), do: []

  defp directory_sources(directory, limits) when is_binary(directory) do
    root = Path.expand(directory)

    unless File.dir?(root) do
      raise ArgumentError, "Snodo.Skills :directory #{inspect(directory)} is not a directory"
    end

    # One walk records every regular file and its size without reading it or
    # following a link; skills are then cut from that list.
    files = walk!(root)

    files
    |> Enum.filter(fn {path, _size} -> Path.basename(path) == "SKILL.md" end)
    |> Enum.map(fn {skill_md, _size} -> directory_source(skill_md, root, files, limits) end)
  end

  defp directory_sources(_directory, _limits),
    do: raise(ArgumentError, "Snodo.Skills :directory must be a path string")

  # Symbolic links are refused rather than followed, so a link cannot make a
  # file outside :directory a public resource. Dotfiles and dot directories
  # are skipped. Only regular files and directories are allowed.
  defp walk!(directory) do
    directory
    |> File.ls!()
    |> Enum.reject(&String.starts_with?(&1, "."))
    |> Enum.sort()
    |> Enum.flat_map(fn name ->
      path = Path.join(directory, name)

      case File.lstat!(path) do
        %File.Stat{type: :regular, size: size} ->
          [{path, size}]

        %File.Stat{type: :directory} ->
          walk!(path)

        %File.Stat{type: :symlink} ->
          raise ArgumentError,
                "#{path}: Snodo.Skills does not follow symbolic links; copy the file into the skill"

        %File.Stat{type: type} ->
          raise ArgumentError, "#{path}: Snodo.Skills serves regular files only, not #{type}"
      end
    end)
  end

  defp directory_source(skill_md, root, files, limits) do
    skill_directory = Path.dirname(skill_md)

    if skill_directory == root do
      raise ArgumentError,
            "#{skill_md}: SKILL.md is at the root of :directory; put each skill in its own directory"
    end

    prefix = skill_directory <> "/"
    stats = Enum.filter(files, fn {path, _size} -> String.starts_with?(path, prefix) end)
    check_listed_limits!(stats, skill_directory, limits)

    %{
      path: Path.relative_to(skill_directory, root),
      files: read_within_budget!(stats, skill_directory, limits.bytes),
      origin: skill_directory,
      external: Enum.map(stats, &elem(&1, 0))
    }
  end

  # The count and the sizes the walk recorded are checked before any file is
  # read, so an oversized skill fails without being loaded.
  defp check_listed_limits!(stats, origin, %{files: max_files, bytes: max_bytes}) do
    check_count!(length(stats), origin, max_files)
    check_total!(stats |> Enum.map(&elem(&1, 1)) |> Enum.sum(), origin, max_bytes)
  end

  # A file can grow between the walk and the read, so each read takes at most
  # the remaining byte budget plus one byte. Getting the extra byte means the
  # skill is over budget, and nothing more of the file is read.
  @doc false
  def read_within_budget!(stats, skill_directory, max_bytes) do
    {files, _total} =
      Enum.map_reduce(stats, 0, fn {path, _size}, total ->
        remaining = max_bytes - total
        bytes = read_at_most!(path, remaining + 1)

        if byte_size(bytes) > remaining do
          raise ArgumentError,
                "#{skill_directory}: the skill's files total more than :max_skill_bytes " <>
                  "(#{max_bytes}); #{path} grew after its size was checked"
        end

        {{Path.relative_to(path, skill_directory), bytes}, total + byte_size(bytes)}
      end)

    files
  end

  @doc false
  def read_at_most!(path, count) when is_integer(count) and count > 0 do
    File.open!(path, [:read, :binary], fn io ->
      case IO.binread(io, count) do
        :eof -> ""
        bytes when is_binary(bytes) -> bytes
        {:error, reason} -> raise File.Error, reason: reason, action: "read file", path: path
      end
    end)
  end

  defp entry_sources(entries) when is_list(entries), do: Enum.map(entries, &entry_source/1)
  defp entry_sources(_entries), do: raise(ArgumentError, "Snodo.Skills :entries must be a list")

  defp entry_source(entry) when is_list(entry) or is_map(entry) do
    entry = Map.new(entry)

    with {:ok, path} when is_binary(path) <- Map.fetch(entry, :path),
         {:ok, files} when is_map(files) <- Map.fetch(entry, :files),
         true <- Enum.all?(files, fn {name, bytes} -> is_binary(name) and is_binary(bytes) end) do
      %{path: path, files: Enum.sort(files), origin: "entry #{inspect(path)}", external: []}
    else
      _invalid ->
        raise ArgumentError,
              "each Snodo.Skills entry needs a :path string and a :files map of relative paths to binaries"
    end
  end

  defp entry_source(_entry),
    do: raise(ArgumentError, "each Snodo.Skills entry must be a keyword list or map")

  defp skill!(source, parser, limits) do
    %{path: path, files: files, origin: origin} = source
    segments = validate_path!(path, origin)
    Enum.each(files, fn {relative, _bytes} -> validate_file_path!(relative, origin) end)

    skill_md =
      case List.keyfind(files, "SKILL.md", 0) do
        {_name, bytes} -> bytes
        nil -> raise ArgumentError, "#{origin}: a skill needs a SKILL.md file at its root"
      end

    check_limits!(files, origin, limits)
    frontmatter = frontmatter!(skill_md, parser, origin)
    name = List.last(segments)

    unless frontmatter["name"] == name do
      raise ArgumentError,
            "#{origin}: the frontmatter name #{inspect(frontmatter["name"])} must equal " <>
              "the skill directory name #{inspect(name)}"
    end

    base = "skill://" <> path
    {[skill_md_file], rest} = Enum.split_with(files, &(elem(&1, 0) == "SKILL.md"))

    %Skill{
      path: path,
      name: name,
      uri: base <> "/SKILL.md",
      frontmatter: frontmatter,
      files: Enum.map([skill_md_file | rest], &file(base, &1))
    }
  end

  defp validate_path!(path, origin) do
    segments = String.split(path, "/")
    {prefix, [name]} = Enum.split(segments, -1)

    unless Regex.match?(@name, name) do
      raise ArgumentError,
            "#{origin}: the skill name #{inspect(name)} must be 1 to 64 lowercase letters, " <>
              "digits, and single hyphens, not starting or ending with a hyphen"
    end

    # "." and ".." would give a URI whose normalized form names another path.
    unless Enum.all?(prefix, &(Regex.match?(@segment, &1) and &1 not in [".", ".."])) do
      raise ArgumentError, "#{origin}: the skill path #{inspect(path)} has an invalid segment"
    end

    segments
  end

  defp validate_file_path!(relative, origin) do
    segments = String.split(relative, "/")

    if relative == "" or Enum.any?(segments, &(&1 in ["", ".", ".."])) or
         String.contains?(relative, "\\") do
      raise ArgumentError, "#{origin}: invalid file path #{inspect(relative)}"
    end

    if relative != "SKILL.md" and List.last(segments) == "SKILL.md" do
      raise ArgumentError,
            "#{origin}: #{relative} would make a skill inside a skill; skills do not nest"
    end
  end

  defp check_limits!(files, origin, %{files: max_files, bytes: max_bytes}) do
    check_count!(length(files), origin, max_files)

    check_total!(
      files |> Enum.map(fn {_name, bytes} -> byte_size(bytes) end) |> Enum.sum(),
      origin,
      max_bytes
    )
  end

  defp check_count!(count, origin, max_files) do
    if count > max_files do
      raise ArgumentError,
            "#{origin}: the skill has #{count} files, more than :max_skill_files (#{max_files})"
    end
  end

  defp check_total!(total, origin, max_bytes) do
    if total > max_bytes do
      raise ArgumentError,
            "#{origin}: the skill's files total #{total} bytes, more than :max_skill_bytes (#{max_bytes})"
    end
  end

  defp frontmatter!(skill_md, parser, origin) do
    case Frontmatter.parse(skill_md, parser: parser) do
      {:ok, frontmatter} ->
        case Enum.reject(
               ["name", "description"],
               &(is_binary(frontmatter[&1]) and frontmatter[&1] != "")
             ) do
          [] ->
            frontmatter

          [key | _rest] ->
            raise ArgumentError, "#{origin}: SKILL.md frontmatter needs a non-empty #{key}"
        end

      {:error, error} ->
        raise ArgumentError, "#{origin}: SKILL.md frontmatter: #{error.message}"
    end
  end

  defp file(base, {relative, bytes}) do
    %{
      path: relative,
      uri: base <> "/" <> encode_path(relative),
      digest: Skill.digest(bytes),
      size: byte_size(bytes),
      mime_type: mime_type(relative, bytes),
      resource: nil,
      content: bytes
    }
  end

  defp encode_path(relative) do
    relative
    |> String.split("/")
    |> Enum.map_join("/", &URI.encode(&1, fn char -> URI.char_unreserved?(char) end))
  end

  defp mime_type(relative, bytes) do
    case Map.fetch(@mime_types, String.downcase(Path.extname(relative))) do
      {:ok, mime_type} -> mime_type
      :error -> if String.valid?(bytes), do: "text/plain", else: "application/octet-stream"
    end
  end

  # Every ancestor of every path is looked up in the set of all paths. Sorted
  # neighbours are not enough: "a", "a-b", "a/b" sort in that order, because
  # "-" sorts before "/", so "a/b" is not next to "a".
  defp reject_overlapping_paths!(skills) do
    counts = Enum.frequencies_by(skills, & &1.path)

    Enum.each(skills, fn skill ->
      if Map.fetch!(counts, skill.path) > 1 do
        raise ArgumentError, "two skills use the path #{inspect(skill.path)}"
      end

      case Enum.find(ancestor_paths(skill.path), &Map.has_key?(counts, &1)) do
        nil ->
          :ok

        ancestor ->
          raise ArgumentError,
                "the skill #{inspect(skill.path)} is inside the skill #{inspect(ancestor)}; skills do not nest"
      end
    end)

    skills
  end

  # "a/b/c" -> ["a", "a/b"]
  defp ancestor_paths(path) do
    segments = String.split(path, "/")

    for count <- 1..(length(segments) - 1)//1,
        do: segments |> Enum.take(count) |> Enum.join("/")
  end

  # One resource module per file, named after the server module and the
  # file's position in the catalog.
  defp define_resources!(skills, module, env) do
    names = skills |> Enum.frequencies_by(& &1.name)

    {skills, {resources, _index}} =
      Enum.map_reduce(skills, {[], 1}, fn skill, acc ->
        {files, acc} =
          Enum.map_reduce(skill.files, acc, fn file, {resources, index} ->
            resource = Module.concat(module, "Resource#{index}")
            define_resource!(resource, skill, file, Map.fetch!(names, skill.name) == 1, env)

            {file |> Map.delete(:content) |> Map.put(:resource, resource),
             {[resource | resources], index + 1}}
          end)

        {%{skill | files: files}, acc}
      end)

    {skills, Enum.reverse(resources)}
  end

  defp define_resource!(resource, skill, file, unique_name?, env) do
    skill_md? = file.path == "SKILL.md"

    definition = %Definition{
      kind: :resource,
      uri: file.uri,
      name: resource_name(skill, file, skill_md? and unique_name?),
      description: if(skill_md?, do: skill.frontmatter["description"]),
      mime_type: file.mime_type,
      size: file.size
    }

    content = content_map(file)

    body =
      quote do
        @moduledoc false
        @behaviour Snodo.Resource

        @impl Snodo.Resource
        def definition, do: unquote(Macro.escape(definition))

        @impl Snodo.Resource
        def matches?(uri) when is_binary(uri), do: uri == unquote(file.uri)

        @impl Snodo.Resource
        def read(_params, _context),
          do: {:ok, Snodo.Result.resource_read(unquote(Macro.escape(content)))}
      end

    {:module, ^resource, _binary, _term} =
      Module.create(resource, body, Macro.Env.location(env))

    :ok
  end

  defp resource_name(skill, _file, true), do: skill.name
  defp resource_name(skill, file, false), do: skill.path <> "/" <> file.path

  # Every directory of a skill, keyed by URI, with its direct children.
  defp directories(%Skill{} = skill) do
    base = "skill://" <> skill.path

    directories =
      skill.files
      |> Enum.flat_map(fn file -> ancestors(Path.dirname(file.path)) end)
      |> Enum.uniq()

    Map.new(directories, fn directory ->
      files =
        for file <- skill.files, parent(file.path) == directory do
          %{
            "uri" => file.uri,
            "name" => Path.basename(file.path),
            "mimeType" => file.mime_type,
            "size" => file.size
          }
        end

      subdirectories =
        for child <- directories, child != "", parent(child) == directory do
          %{
            "uri" => directory_uri(base, child),
            "name" => Path.basename(child),
            "mimeType" => @directory_mime_type
          }
        end

      {directory_uri(base, directory), Enum.sort_by(subdirectories ++ files, & &1["uri"])}
    end)
  end

  defp ancestors("."), do: [""]
  defp ancestors(directory), do: [directory | ancestors(Path.dirname(directory))]

  defp parent(path) do
    case Path.dirname(path) do
      "." -> ""
      directory -> directory
    end
  end

  defp directory_uri(base, ""), do: base
  defp directory_uri(base, directory), do: base <> "/" <> encode_path(directory)

  defp scope(entries) do
    entries
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> binary_part(0, 12)
    |> Base.url_encode64(padding: false)
  end
end
