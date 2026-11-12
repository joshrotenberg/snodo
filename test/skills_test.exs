defmodule Snodo.SkillsTest do
  use ExUnit.Case, async: true

  alias Snodo.Client
  alias Snodo.Skills.Catalog
  alias Snodo.Skills.Skill
  alias SnodoTest.Skills
  alias SnodoTest.SkillsServer

  @fixtures "test/fixtures/skills"

  defp client(opts \\ [client_capabilities: Snodo.Skills.Client.capabilities()]) do
    {:ok, client} = Client.direct(SkillsServer.runtime(), opts)
    client
  end

  defp file(path), do: File.read!(Path.join(@fixtures, path))

  describe "the catalog" do
    test "reads skills from the directory and from entries, sorted by path" do
      assert Enum.map(Skills.skills(), & &1.path) == [
               "acme/release-notes",
               "inline-tool",
               "pdf-processing"
             ]

      pdf = Enum.find(Skills.skills(), &(&1.name == "pdf-processing"))
      assert pdf.uri == "skill://pdf-processing/SKILL.md"

      assert pdf.frontmatter == %{
               "name" => "pdf-processing",
               "description" => "Extract, fill, and assemble PDF documents",
               "license" => "Apache-2.0",
               "metadata" => %{"author" => "snodo-tests"}
             }

      assert Enum.map(pdf.files, & &1.path) == [
               "SKILL.md",
               "references/FORMS.md",
               "scripts/fill.py"
             ]

      forms = Enum.at(pdf.files, 1)
      bytes = file("pdf-processing/references/FORMS.md")
      assert forms.uri == "skill://pdf-processing/references/FORMS.md"
      assert forms.size == byte_size(bytes)

      assert forms.digest ==
               "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

      assert forms.mime_type == "text/markdown"
      assert Enum.at(pdf.files, 2).mime_type == "text/x-python"
    end

    test "builds the wire entry with every file once, SKILL.md first" do
      [notes | _rest] = Skills.skills()

      assert Skill.entry(notes) == %{
               "uri" => "skill://acme/release-notes/SKILL.md",
               "frontmatter" => %{
                 "name" => "release-notes",
                 "description" => "Write release notes from merged changes",
                 "allowed-tools" => ["Read", "Grep"]
               },
               "resources" => [
                 %{
                   "uri" => "skill://acme/release-notes/SKILL.md",
                   "digest" => Skill.digest(file("acme/release-notes/SKILL.md")),
                   "size" => byte_size(file("acme/release-notes/SKILL.md"))
                 }
               ]
             }
    end

    test "advertises the extension next to the resources capability" do
      assert Skills.capabilities(%{"tools" => %{}}) == %{
               "tools" => %{},
               "resources" => %{},
               "extensions" => %{"io.modelcontextprotocol/skills" => %{"directoryRead" => true}}
             }

      assert {:ok, discovery} = Client.discover(client())

      assert discovery["capabilities"]["extensions"] == %{
               "io.modelcontextprotocol/skills" => %{"directoryRead" => true}
             }
    end
  end

  describe "skills/list and skills/get" do
    test "pages the listing without splitting an entry" do
      client = client()

      assert {:ok, first} = Client.request(client, "skills/list")
      assert first["resultType"] == "complete"
      assert first["ttlMs"] == 0
      assert first["cacheScope"] == "private"
      assert length(first["skills"]) == 2

      assert {:ok, second} =
               Client.request(client, "skills/list", %{"cursor" => first["nextCursor"]})

      refute Map.has_key?(second, "nextCursor")

      assert Enum.map(first["skills"] ++ second["skills"], & &1["uri"]) == [
               "skill://acme/release-notes/SKILL.md",
               "skill://inline-tool/SKILL.md",
               "skill://pdf-processing/SKILL.md"
             ]
    end

    test "refuses a cursor from another listing" do
      client = client()
      {:ok, %{"nextCursor" => cursor}} = Client.request(client, "skills/list")

      for bad <- [cursor <> "x", "skills1.e30", 5] do
        assert {:error, %Snodo.Error{code: -32_602}} =
                 Client.request(client, "skills/list", %{"cursor" => bad})
      end

      {:ok, %{"nextCursor" => directory_cursor}} =
        Client.request(client, "resources/directory/read", %{"uri" => "skill://pdf-processing"})

      assert {:error, %Snodo.Error{code: -32_602}} =
               Client.request(client, "skills/list", %{"cursor" => directory_cursor})
    end

    test "gets one entry and refuses an unknown skill with -32602" do
      client = client()

      assert {:ok, result} =
               Client.request(client, "skills/get", %{"uri" => "skill://pdf-processing/SKILL.md"})

      assert result["skill"] == Skill.entry(Enum.at(Skills.skills(), 2))
      assert result["ttlMs"] == 0 and result["cacheScope"] == "private"
      refute Map.has_key?(result, "nextCursor")

      assert {:error, %Snodo.Error{code: -32_602, data: %{"uri" => "skill://nope/SKILL.md"}}} =
               Client.request(client, "skills/get", %{"uri" => "skill://nope/SKILL.md"})

      assert {:error, %Snodo.Error{code: -32_602}} = Client.request(client, "skills/get", %{})
    end

    test "answers -32021 to a client that did not declare the extension" do
      client = client([])

      for method <- ["skills/list", "skills/get", "resources/directory/read"] do
        assert {:error, %Snodo.Error{code: -32_021, data: data}} =
                 Client.request(client, method, %{"uri" => "skill://pdf-processing"})

        assert data == %{
                 "requiredCapabilities" => %{
                   "extensions" => %{"io.modelcontextprotocol/skills" => %{}}
                 }
               }
      end
    end
  end

  describe "resources/directory/read" do
    test "lists direct children, subdirectories as inode/directory, in pages" do
      client = client()
      uri = "skill://pdf-processing"

      assert {:ok, first} = Client.request(client, "resources/directory/read", %{"uri" => uri})

      assert {:ok, second} =
               Client.request(client, "resources/directory/read", %{
                 "uri" => uri,
                 "cursor" => first["nextCursor"]
               })

      assert first["resultType"] == "complete"
      refute Map.has_key?(second, "nextCursor")

      assert first["resources"] ++ second["resources"] == [
               %{
                 "uri" => "skill://pdf-processing/SKILL.md",
                 "name" => "SKILL.md",
                 "mimeType" => "text/markdown",
                 "size" => byte_size(file("pdf-processing/SKILL.md"))
               },
               %{
                 "uri" => "skill://pdf-processing/references",
                 "name" => "references",
                 "mimeType" => "inode/directory"
               },
               %{
                 "uri" => "skill://pdf-processing/scripts",
                 "name" => "scripts",
                 "mimeType" => "inode/directory"
               }
             ]

      assert {:ok, %{"resources" => [%{"name" => "FORMS.md"}]}} =
               Client.request(client, "resources/directory/read", %{
                 "uri" => "skill://pdf-processing/references/"
               })
    end

    test "refuses a URI that is not a skill directory with -32602" do
      client = client()

      for uri <- ["skill://pdf-processing/SKILL.md", "skill://acme", "file:///tmp"] do
        assert {:error, %Snodo.Error{code: -32_602, data: %{"uri" => ^uri}}} =
                 Client.request(client, "resources/directory/read", %{"uri" => uri})
      end
    end
  end

  describe "skill files as resources" do
    test "lists every file, SKILL.md with its frontmatter name and description" do
      assert {:ok, resources} = Client.list_resources(client([]))
      skill_md = Enum.find(resources, &(&1["uri"] == "skill://pdf-processing/SKILL.md"))

      assert skill_md == %{
               "uri" => "skill://pdf-processing/SKILL.md",
               "name" => "pdf-processing",
               "description" => "Extract, fill, and assemble PDF documents",
               "mimeType" => "text/markdown",
               "size" => byte_size(file("pdf-processing/SKILL.md"))
             }

      assert length(resources) == 6
      assert Enum.any?(resources, &(&1["name"] == "pdf-processing/references/FORMS.md"))
    end

    test "serves text files as text and other bytes as a blob" do
      client = client([])

      assert {:ok, %{"contents" => [content]}} =
               Client.read_resource(client, "skill://pdf-processing/references/FORMS.md")

      assert content["text"] == file("pdf-processing/references/FORMS.md")

      assert {:ok, %{"contents" => [blob]}} =
               Client.read_resource(client, "skill://inline-tool/data/blob.bin")

      assert Base.decode64!(blob["blob"]) == <<0, 159, 146, 150, 255>>
      assert blob["mimeType"] == "application/octet-stream"
    end
  end

  defp build(opts) do
    module = Module.concat(__MODULE__, "Build#{System.unique_integer([:positive])}")
    Catalog.build!(opts, module, __ENV__)
  end

  defp skill_md(name, extra \\ ""),
    do: "---\nname: #{name}\ndescription: A test skill\n#{extra}---\nBody\n"

  describe "reading a skill directory" do
    defp write_skill!(directory, name, files \\ %{}) do
      skill = Path.join(directory, name)
      File.mkdir_p!(skill)
      File.write!(Path.join(skill, "SKILL.md"), skill_md(name))

      for {relative, bytes} <- files do
        path = Path.join(skill, relative)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, bytes)
      end

      skill
    end

    defp build_error(opts) do
      error = assert_raise ArgumentError, fn -> build(opts) end
      error.message
    end

    @tag :tmp_dir
    test "refuses a symlinked supporting file instead of serving its target", %{tmp_dir: tmp} do
      outside = Path.join(tmp, "outside.txt")
      File.write!(outside, "secret")
      skills = Path.join(tmp, "skills")
      skill = write_skill!(skills, "linked")
      File.ln_s!(outside, Path.join(skill, "notes.txt"))

      assert build_error(directory: skills) =~ "does not follow symbolic links"
    end

    @tag :tmp_dir
    test "refuses a symlinked SKILL.md and a symlinked ancestor directory", %{tmp_dir: tmp} do
      elsewhere = Path.join(tmp, "elsewhere")
      write_skill!(elsewhere, "remote")

      linked_md = Path.join(tmp, "md")
      File.mkdir_p!(Path.join(linked_md, "remote"))

      File.ln_s!(
        Path.join([elsewhere, "remote", "SKILL.md"]),
        Path.join([linked_md, "remote", "SKILL.md"])
      )

      assert build_error(directory: linked_md) =~ "does not follow symbolic links"

      linked_dir = Path.join(tmp, "dir")
      File.mkdir_p!(linked_dir)
      File.ln_s!(elsewhere, Path.join(linked_dir, "acme"))
      assert build_error(directory: linked_dir) =~ "does not follow symbolic links"
    end

    @tag :tmp_dir
    test "checks the byte budget from file sizes before reading anything", %{tmp_dir: tmp} do
      skills = Path.join(tmp, "skills")
      skill = write_skill!(skills, "big", %{"data.bin" => String.duplicate("x", 64)})
      # Unreadable: reading it first would raise File.Error instead.
      File.chmod!(Path.join(skill, "data.bin"), 0o000)
      on_exit(fn -> File.chmod(Path.join(skill, "data.bin"), 0o644) end)

      assert build_error(directory: skills, max_skill_bytes: 32) =~ ":max_skill_bytes (32)"
    end

    @tag :tmp_dir
    test "checks the file count before reading anything", %{tmp_dir: tmp} do
      skills = Path.join(tmp, "skills")
      skill = write_skill!(skills, "many", %{"a.txt" => "a", "b.txt" => "b"})
      File.chmod!(Path.join(skill, "b.txt"), 0o000)
      on_exit(fn -> File.chmod(Path.join(skill, "b.txt"), 0o644) end)

      assert build_error(directory: skills, max_skill_files: 2) =~ ":max_skill_files (2)"
    end

    @tag :tmp_dir
    test "bounds each read by the remaining byte budget when a file outgrows its size",
         %{tmp_dir: tmp} do
      # Recorded at size 0, as if the file grew to 1 MiB after the walk.
      path = Path.join(tmp, "grown.txt")
      File.write!(path, String.duplicate("x", 1_048_576))

      # The read itself stops at the remaining budget plus one byte.
      assert byte_size(Catalog.read_at_most!(path, 11)) == 11

      error =
        assert_raise ArgumentError, fn -> Catalog.read_within_budget!([{path, 0}], tmp, 10) end

      assert error.message =~ ":max_skill_bytes (10)"
      assert error.message =~ "grew after its size was checked"

      # The budget is shared: the second file only gets what the first left.
      small = Path.join(tmp, "small.txt")
      File.write!(small, String.duplicate("y", 8))

      assert_raise ArgumentError, fn ->
        Catalog.read_within_budget!([{small, 8}, {path, 0}], tmp, 12)
      end

      exact = Path.join(tmp, "exact.txt")
      File.write!(exact, String.duplicate("z", 20))
      assert [{"exact.txt", bytes}] = Catalog.read_within_budget!([{exact, 0}], tmp, 20)
      assert byte_size(bytes) == 20
      assert Catalog.read_at_most!(Path.join(tmp, "small.txt"), 100) == String.duplicate("y", 8)
    end

    @tag :tmp_dir
    test "asks Mix to recompile when a file is added, removed, or changed", %{tmp_dir: tmp} do
      skills = Path.join(tmp, "skills")
      skill = write_skill!(skills, "first", %{"docs/a.md" => "a"})
      module = Module.concat(__MODULE__, "Recompile#{System.unique_integer([:positive])}")

      Code.compile_quoted(
        quote do
          defmodule unquote(module) do
            use Snodo.Skills, directory: unquote(skills)
          end
        end
      )

      refute module.__mix_recompile__?()

      # A new skill, which no @external_resource covers.
      second = write_skill!(skills, "second")
      assert module.__mix_recompile__?()
      File.rm_rf!(second)
      refute module.__mix_recompile__?()

      # A new file deep inside an existing skill.
      nested = Path.join(skill, "docs/more/b.md")
      File.mkdir_p!(Path.dirname(nested))
      File.write!(nested, "b")
      assert module.__mix_recompile__?()
      File.rm_rf!(Path.join(skill, "docs/more"))
      refute module.__mix_recompile__?()

      # A removed file, and a changed one.
      File.rm!(Path.join(skill, "docs/a.md"))
      assert module.__mix_recompile__?()
      File.write!(Path.join(skill, "docs/a.md"), "a changed")
      assert module.__mix_recompile__?()

      # Dotfiles are not served, so they do not count.
      File.write!(Path.join(skill, "docs/a.md"), "a")
      fingerprint = Catalog.fingerprint(skills)
      File.write!(Path.join(skill, ".hidden"), "x")
      assert Catalog.fingerprint(skills) == fingerprint

      # A module built only from :entries has nothing to watch.
      entries_only = Module.concat(__MODULE__, "Entries#{System.unique_integer([:positive])}")

      Code.compile_quoted(
        quote do
          defmodule unquote(entries_only) do
            use Snodo.Skills,
              entries: [[path: "solo", files: %{"SKILL.md" => unquote(skill_md("solo"))}]]
          end
        end
      )

      assert entries_only.__catalog__().directory == nil
      refute function_exported?(entries_only, :__mix_recompile__?, 0)

      # The test support module reads test/fixtures/skills, which is unchanged.
      refute SnodoTest.Skills.__mix_recompile__?()
    end

    @tag :tmp_dir
    test "skips dotfiles and reads nested directories", %{tmp_dir: tmp} do
      skills = Path.join(tmp, "skills")
      write_skill!(skills, "plain", %{".hidden" => "x", "a/b/c.txt" => "c"})

      {catalog, _resources} = build(directory: skills)
      assert [%{files: files}] = catalog.skills
      assert Enum.map(files, & &1.path) == ["SKILL.md", "a/b/c.txt"]
    end
  end

  describe "response size" do
    defp pages(catalog, operation, params, key) do
      context = %Snodo.Context{
        protocol_version: "2026-07-28",
        protocol: Snodo.Protocol.V2026_07_28,
        transport: %Snodo.Transport.Context{transport: :direct}
      }

      params
      |> Stream.unfold(fn
        nil ->
          nil

        params ->
          assert {:ok, %Snodo.Result{value: result}} =
                   Snodo.Skills.dispatch(catalog, operation, params, context)

          next = if cursor = result["nextCursor"], do: Map.put(params, "cursor", cursor)
          {result[key], next}
      end)
      |> Enum.to_list()
    end

    # The larger of the HTTP and stdio sizes of any JSON value, measured with
    # the stdio framing itself: {"v":<value>} and a newline, less 7 bytes.
    defp encoded(value) do
      http = value |> JSON.encode!() |> byte_size()
      stdio = IO.iodata_length(Snodo.Transport.Stdio.Framing.encode_message(%{"v" => value})) - 7
      max(http, stdio)
    end

    test "measures text as the stdio framing sends it, every non-ASCII character escaped" do
      # 1,500 "é" are 3,000 bytes over HTTP and 9,000 on stdio.
      accents = String.duplicate("é", 1_500)
      assert byte_size(JSON.encode!(accents)) < 4_096
      assert encoded(accents) > 4_096

      error =
        assert_raise ArgumentError, fn ->
          build(
            entries: [
              [path: "accents", files: %{"SKILL.md" => skill_md("accents"), "é.txt" => accents}]
            ],
            max_response_bytes: 8_192
          )
        end

      assert error.message =~ "accents/é.txt: resources/read would send"

      # A character above U+FFFF is a surrogate pair, 12 bytes.
      assert Catalog.encoded_size(%{"t" => "𝄞"}) == byte_size(~s({"t":"\\ud834\\udd1e"}))
      assert Catalog.encoded_size(%{"t" => "a"}) == byte_size(~s({"t":"a"}))

      # The same check at the defaults: three million "é" are 6,000,000 bytes
      # over HTTP, inside the budget, and 18,000,000 on stdio, past it.
      error =
        assert_raise ArgumentError, fn ->
          build(
            entries: [
              [
                path: "many",
                files: %{
                  "SKILL.md" => skill_md("many"),
                  "notes.txt" => String.duplicate("é", 3_000_000)
                }
              ]
            ]
          )
        end

      assert error.message =~ ~r/resources\/read would send 180000\d\d bytes/
    end

    test "cuts skills/list pages by their stdio size" do
      description = String.duplicate("é", 300)

      entries =
        for n <- 1..4 do
          name = "skill-#{n}"

          [
            path: name,
            files: %{"SKILL.md" => skill_md(name) |> String.replace("A test skill", description)}
          ]
        end

      {catalog, _resources} = build(entries: entries, max_response_bytes: 8_192)
      pages = pages(catalog, :skills_list, %{}, "skills")
      assert Enum.concat(pages) == catalog.entries
      # Over HTTP the four entries would fit on one page.
      assert byte_size(JSON.encode!(catalog.entries)) < 4_096
      assert length(pages) > 1
      assert Enum.all?(pages, &(encoded(&1) <= 4_096))
    end

    test "refuses a file whose resources/read content would pass :max_response_bytes" do
      # 8,192 less the 4,096-byte envelope leaves 4,096 bytes of content.
      cases = [
        {"text.md", String.duplicate("a", 4_100)},
        # Base64 makes 3,100 bytes 4,136.
        {"data.bin", :binary.copy(<<255>>, 3_100)},
        # Valid UTF-8, so sent as text, but JSON escapes each byte as \u0001.
        {"controls.txt", :binary.copy(<<1>>, 700)}
      ]

      for {name, bytes} <- cases do
        error =
          assert_raise ArgumentError, fn ->
            build(
              entries: [[path: "big", files: %{"SKILL.md" => skill_md("big"), name => bytes}]],
              max_response_bytes: 8_192
            )
          end

        assert error.message =~ "big/#{name}: resources/read would send"
        assert error.message =~ ":max_response_bytes (8192) less 4096 bytes"
      end

      # The same sizes in plain text fit.
      {catalog, _resources} =
        build(
          entries: [
            [
              path: "fits",
              files: %{
                "SKILL.md" => skill_md("fits"),
                "a.txt" => String.duplicate("a", 3_100),
                "b.txt" => String.duplicate("b", 700)
              }
            ]
          ],
          max_response_bytes: 8_192
        )

      assert [%{files: [_, _, _]}] = catalog.skills
    end

    test "at the defaults, refuses files a default client could not read" do
      skill = skill_md("large")
      # Within :max_skill_bytes, but over 16 MiB once in a response.
      text = String.duplicate("a", 16_777_216 - byte_size(skill))
      binary = :binary.copy(<<255>>, 12_600_000)

      for {name, bytes} <- [{"text.txt", text}, {"data.bin", binary}] do
        error =
          assert_raise ArgumentError, fn ->
            build(entries: [[path: "large", files: %{"SKILL.md" => skill, name => bytes}]])
          end

        assert error.message =~ ":max_response_bytes (16777216)"
      end
    end

    test "refuses a skills/get entry over :max_response_bytes" do
      files = for n <- 1..60, into: %{"SKILL.md" => skill_md("wide")}, do: {"f#{n}.txt", "x"}

      error =
        assert_raise ArgumentError, fn ->
          build(entries: [[path: "wide", files: files]], max_response_bytes: 8_192)
        end

      assert error.message =~ "wide: the skill's skills/get entry is"
    end

    test "cuts skills/list pages to :max_response_bytes" do
      entries =
        for n <- 1..7 do
          name = "skill-#{n}"
          files = for f <- 1..10, into: %{"SKILL.md" => skill_md(name)}, do: {"f#{f}.txt", "x"}
          [path: name, files: files]
        end

      {catalog, _resources} = build(entries: entries, max_response_bytes: 8_192)
      assert Enum.all?(catalog.entries, &(encoded(&1) < 4_096))

      pages = pages(catalog, :skills_list, %{}, "skills")
      assert Enum.concat(pages) == catalog.entries
      assert length(pages) > 1
      assert Enum.all?(pages, &(encoded(&1) <= 4_096))
      assert Enum.any?(pages, &(length(&1) > 1))

      # The default budget is the default client limit less the envelope.
      {default, _resources} = build(entries: entries)
      assert default.response_budget == 16_777_216 - 4_096
      assert pages(default, :skills_list, %{}, "skills") == [default.entries]
    end

    test "cuts resources/directory/read pages to :max_response_bytes" do
      # A child repeats its long name next to its URI, so with long names a
      # directory listing outgrows the skill entry, which has to fit.
      name = String.duplicate("n", 200)

      files =
        for n <- 1..120, into: %{"SKILL.md" => skill_md("dir")}, do: {"docs/#{name}#{n}", "x"}

      {wide, _resources} = build(entries: [[path: "dir", files: files]])
      [entry_bytes] = wide.entry_bytes
      max_response_bytes = entry_bytes + 4_096 + 16
      budget = max_response_bytes - 4_096
      assert encoded(wide.directories["skill://dir/docs"]) > budget

      {catalog, _resources} =
        build(entries: [[path: "dir", files: files]], max_response_bytes: max_response_bytes)

      pages = pages(catalog, :directory_read, %{"uri" => "skill://dir/docs"}, "resources")
      assert length(pages) > 1
      assert Enum.concat(pages) == catalog.directories["skill://dir/docs"]
      assert Enum.all?(pages, &(encoded(&1) <= budget and length(&1) < 100))
    end

    test "requires :max_response_bytes above the envelope" do
      for value <- [4_096, 0, "big"] do
        error =
          assert_raise ArgumentError, fn ->
            build(
              entries: [[path: "a", files: %{"SKILL.md" => skill_md("a")}]],
              max_response_bytes: value
            )
          end

        assert error.message =~ ":max_response_bytes must be an integer greater than 4096"
      end
    end
  end

  describe "directory cursors" do
    test "stay small for a long directory URI and are bound to their directory" do
      prefix = Enum.map_join(1..4, "/", fn index -> String.duplicate("p#{index}", 100) end)
      path = prefix <> "/long-skill"

      files =
        for n <- 1..3,
            into: %{"SKILL.md" => skill_md("long-skill")},
            do: {"docs/f#{n}.md", "#{n}"}

      {catalog, _resources} = build(entries: [[path: path, files: files]], directory_page_size: 1)
      directory = "skill://#{path}/docs"
      assert byte_size(directory) > 800

      context = %Snodo.Context{
        protocol_version: "2026-07-28",
        protocol: Snodo.Protocol.V2026_07_28,
        transport: %Snodo.Transport.Context{transport: :direct}
      }

      read = fn params -> Snodo.Skills.dispatch(catalog, :directory_read, params, context) end

      names =
        Stream.unfold(%{"uri" => directory}, fn
          nil ->
            nil

          params ->
            assert {:ok, %Snodo.Result{value: result}} = read.(params)
            cursor = result["nextCursor"]
            if cursor, do: assert(byte_size(cursor) < 128)
            next = if cursor, do: %{"uri" => directory, "cursor" => cursor}
            {Enum.map(result["resources"], & &1["name"]), next}
        end)
        |> Enum.concat()

      assert names == ["f1.md", "f2.md", "f3.md"]

      {:ok, %Snodo.Result{value: %{"nextCursor" => cursor}}} = read.(%{"uri" => directory})

      assert {:error, %Snodo.Error{code: -32_602}} =
               read.(%{"uri" => "skill://#{path}", "cursor" => cursor})
    end
  end

  describe "building a catalog" do
    test "can leave out resources/directory/read" do
      {catalog, [resource]} =
        build(
          entries: [[path: "solo", files: %{"SKILL.md" => skill_md("solo")}]],
          directory_read: false
        )

      refute catalog.directory_read
      assert Snodo.Skills.methods(false) |> Enum.map(& &1.name) == ["skills/list", "skills/get"]
      assert resource.definition().uri == "skill://solo/SKILL.md"
    end

    test "refuses invalid skills with ArgumentError" do
      cases = [
        {[entries: [[path: "a", files: %{"README.md" => "x"}]]], "SKILL.md"},
        {[entries: [[path: "Bad_Name", files: %{"SKILL.md" => skill_md("Bad_Name")}]]],
         "skill name"},
        {[entries: [[path: "a--b", files: %{"SKILL.md" => skill_md("a--b")}]]], "skill name"},
        {[entries: [[path: "acme/../pdf", files: %{"SKILL.md" => skill_md("pdf")}]]],
         "invalid segment"},
        {[entries: [[path: "./pdf", files: %{"SKILL.md" => skill_md("pdf")}]]],
         "invalid segment"},
        {[entries: [[path: "acme//pdf", files: %{"SKILL.md" => skill_md("pdf")}]]],
         "invalid segment"},
        {[entries: [[path: "other", files: %{"SKILL.md" => skill_md("mismatch")}]]],
         "must equal"},
        {[entries: [[path: "a", files: %{"SKILL.md" => "---\nname: a\n---\n"}]]], "description"},
        {[entries: [[path: "a", files: %{"SKILL.md" => "no frontmatter"}]]], "frontmatter"},
        {[entries: [[path: "a", files: %{"SKILL.md" => skill_md("a", "notes: |\n  x\n")}]]],
         "block scalar"},
        {[entries: [[path: "a", files: %{"SKILL.md" => skill_md("a"), "../x" => ""}]]],
         "invalid file path"},
        {[entries: [[path: "a", files: %{"SKILL.md" => skill_md("a"), "b/SKILL.md" => ""}]]],
         "do not nest"},
        {[
           entries: [
             [path: "a", files: %{"SKILL.md" => skill_md("a")}],
             [path: "a", files: %{"SKILL.md" => skill_md("a")}]
           ]
         ], "two skills"},
        {[
           entries: [[path: "a", files: %{"SKILL.md" => skill_md("a"), "x" => ""}]],
           max_skill_files: 1
         ], ":max_skill_files (1)"},
        {[entries: [[path: "a", files: %{"SKILL.md" => skill_md("a")}]], max_skill_bytes: 10],
         ":max_skill_bytes (10)"},
        {[entries: [[path: "a", files: %{"SKILL.md" => skill_md("a")}]], page_size: 0],
         ":page_size"},
        {[directory: "test/fixtures/missing"], "not a directory"},
        {[entries: [], unknown: true], "unknown"},
        {[], ":directory, :entries"}
      ]

      for {opts, fragment} <- cases do
        error = assert_raise ArgumentError, fn -> build(opts) end
        assert error.message =~ fragment, "#{inspect(opts)}: #{error.message}"
      end
    end

    test "refuses a skill inside another even when a sibling sorts between them" do
      # "a-b" sorts between "a" and "a/b", so a check of sorted neighbours
      # alone would accept "a/b" inside "a".
      skill = fn path ->
        [path: path, files: %{"SKILL.md" => skill_md(path |> String.split("/") |> List.last())}]
      end

      for paths <- [["a", "a-b", "a/b"], ["a/b", "a-b", "a"], ["x/a", "x/a-b", "x/a-c", "x/a/c"]] do
        error = assert_raise ArgumentError, fn -> build(entries: Enum.map(paths, skill)) end
        assert error.message =~ "skills do not nest", inspect(paths)
      end

      error =
        assert_raise ArgumentError, fn ->
          build(entries: Enum.map(["acme/a", "acme/a-b", "acme/a/b/c"], skill))
        end

      assert error.message =~ ~s(the skill "acme/a/b/c" is inside the skill "acme/a")

      {catalog, _resources} = build(entries: Enum.map(["a", "a-b", "ab/c", "b/a"], skill))
      assert Enum.map(catalog.skills, & &1.path) == ["a", "a-b", "ab/c", "b/a"]
    end

    test "reads frontmatter with a configured parser" do
      parser = fn _yaml -> {:ok, %{"name" => "custom", "description" => "From the parser"}} end

      {catalog, _resources} =
        build(
          entries: [[path: "custom", files: %{"SKILL.md" => "---\nanything: |\n  goes\n---\n"}]],
          frontmatter_parser: parser
        )

      assert [%{frontmatter: %{"description" => "From the parser"}}] = catalog.skills
    end
  end
end
