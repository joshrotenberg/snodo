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
    test "enforces the byte budget on what is read when a file outgrows its size", %{tmp_dir: tmp} do
      path = Path.join(tmp, "grown.txt")
      File.write!(path, String.duplicate("x", 20))

      error =
        assert_raise ArgumentError, fn -> Catalog.read_within_budget!([{path, 0}], tmp, 10) end

      assert error.message =~ ":max_skill_bytes (10)"
      assert [{"grown.txt", _bytes}] = Catalog.read_within_budget!([{path, 0}], tmp, 20)
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
