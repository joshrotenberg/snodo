defmodule Snodo.Skills.ClientTest.LongNumberSkill do
  @moduledoc false
  # A SKILL.md a hostile server could send: a number of 1,900,000 digits,
  # inside the default transport limits. String.to_integer/1 raises
  # SystemLimitError for it.
  @behaviour Snodo.Resource

  @uri "skill://long-number/SKILL.md"

  def uri, do: @uri

  def text,
    do:
      "---\nname: long-number\ndescription: d\ncount: #{String.duplicate("7", 1_900_000)}\n---\n"

  @impl Snodo.Resource
  def definition,
    do: %Snodo.Resource.Definition{kind: :resource, uri: @uri, name: "long-number"}

  @impl Snodo.Resource
  def matches?(uri), do: uri == @uri

  @impl Snodo.Resource
  def read(_params, _context),
    do: {:ok, Snodo.Result.resource_read(Snodo.Resource.text(@uri, text()))}
end

defmodule Snodo.Skills.ClientTest.LongNumberServer do
  @moduledoc false
  use Snodo.Server, name: "long-number", version: "1.0.0"

  resource(Snodo.Skills.ClientTest.LongNumberSkill)
end

defmodule Snodo.Skills.ClientTest do
  use ExUnit.Case, async: true

  alias Snodo.Client
  alias Snodo.Error
  alias Snodo.Skills.Client, as: Skills
  alias Snodo.Skills.Skill
  alias SnodoTest.SkillsServer

  @skill_md "skill://pdf-processing/SKILL.md"
  @forms "skill://pdf-processing/references/FORMS.md"

  setup do
    {:ok, client} =
      Client.direct(SkillsServer.runtime(), client_capabilities: Skills.capabilities())

    {:ok, entry} = Skills.get(client, @skill_md)
    %{client: client, entry: entry}
  end

  defp put_resource(entry, uri, fun) do
    resources =
      Enum.map(entry["resources"], fn
        %{"uri" => ^uri} = resource -> fun.(resource)
        resource -> resource
      end)

    %{entry | "resources" => resources}
  end

  defp failure({:error, %Error{code: -32_000, kind: :extension, data: data}}), do: data

  test "declares the extension" do
    assert Skills.capabilities() == %{"extensions" => %{"io.modelcontextprotocol/skills" => %{}}}
  end

  test "lists every skill across pages", %{client: client} do
    assert {:ok, entries} = Skills.list(client)

    assert Enum.map(entries, & &1["uri"]) == [
             "skill://acme/release-notes/SKILL.md",
             "skill://inline-tool/SKILL.md",
             @skill_md
           ]

    assert {:error, %Error{code: -32_000, kind: :transport}} = Skills.list(client, max_pages: 1)
  end

  test "gets an entry and passes server errors through", %{client: client, entry: entry} do
    assert entry["frontmatter"]["name"] == "pdf-processing"
    assert {:error, %Error{code: -32_602}} = Skills.get(client, "skill://nope/SKILL.md")
  end

  test "a client that does not declare the extension gets -32021" do
    {:ok, client} = Client.direct(SkillsServer.runtime())
    assert {:error, %Error{code: -32_021}} = Skills.list(client)
  end

  test "loads SKILL.md and reads a listed file after verifying them", %{
    client: client,
    entry: entry
  } do
    assert {:ok, %{"uri" => @skill_md, "text" => "---\nname: pdf-processing" <> _rest}} =
             Skills.load(client, entry)

    assert {:ok, %{"text" => "# Forms" <> _rest}} = Skills.read(client, entry, @forms)

    {:ok, inline} = Skills.get(client, "skill://inline-tool/SKILL.md")

    assert {:ok, %{"blob" => _blob}} =
             Skills.read(client, inline, "skill://inline-tool/data/blob.bin")
  end

  test "refuses content whose digest does not match", %{client: client, entry: entry} do
    tampered = put_resource(entry, @forms, &Map.put(&1, "digest", Skill.digest("other")))

    assert %{"uri" => @forms, "reason" => "digest_mismatch", "expected" => expected} =
             failure(Skills.read(client, tampered, @forms))

    assert expected == Skill.digest("other")
  end

  test "refuses content whose size does not match", %{client: client, entry: entry} do
    tampered = put_resource(entry, @skill_md, &Map.update!(&1, "size", fn size -> size + 1 end))
    assert %{"reason" => "size_mismatch"} = failure(Skills.load(client, tampered))
  end

  test "refuses a SKILL.md whose frontmatter differs from the entry", %{
    client: client,
    entry: entry
  } do
    tampered = put_in(entry, ["frontmatter", "description"], "Exfiltrate credentials")

    assert %{"reason" => "frontmatter_mismatch", "fields" => ["description"]} =
             failure(Skills.load(client, tampered))

    extra = put_in(entry, ["frontmatter", "license"], nil)
    assert %{"fields" => ["license"]} = failure(Skills.load(client, extra))

    missing_null = put_in(entry, ["frontmatter", "unset"], nil)
    assert {:ok, _content} = Skills.load(client, missing_null)
  end

  test "refuses files the entry does not list or lists as too large", %{
    client: client,
    entry: entry
  } do
    assert %{"reason" => "not_listed"} =
             failure(Skills.read(client, entry, "skill://pdf-processing/other.md"))

    assert %{"reason" => "too_large", "maxFileBytes" => 10} =
             failure(Skills.read(client, entry, @forms, max_file_bytes: 10))

    malformed = put_resource(entry, @forms, &Map.delete(&1, "digest"))
    assert %{"reason" => "malformed_entry"} = failure(Skills.read(client, malformed, @forms))
  end

  test "verifies a result without sending a request", %{entry: entry} do
    bytes = "# Forms\n\nFill each field in document order.\n"
    result = %{"contents" => [%{"uri" => @forms, "text" => bytes}]}
    assert {:ok, %{"text" => ^bytes}} = Skills.verify(entry, @forms, result)

    assert %{"reason" => "missing_content"} =
             failure(Skills.verify(entry, @forms, %{"contents" => []}))

    assert %{"reason" => "digest_mismatch"} =
             failure(
               Skills.verify(entry, @forms, %{
                 "contents" => [%{"uri" => @forms, "text" => String.upcase(bytes)}]
               })
             )
  end

  test "checks only the frontmatter of a dynamic entry", %{entry: entry} do
    dynamic = Map.put(entry, "resources", "dynamic")
    skill_md = File.read!("test/fixtures/skills/pdf-processing/SKILL.md")
    result = %{"contents" => [%{"uri" => @skill_md, "text" => skill_md}]}

    assert {:ok, _content} = Skills.verify(dynamic, @skill_md, result)

    unreadable = %{"contents" => [%{"uri" => @skill_md, "text" => "no frontmatter"}]}

    assert %{"reason" => "frontmatter_unreadable"} =
             failure(Skills.verify(dynamic, @skill_md, unreadable))

    # A value the subset cannot represent is reported, not raised.
    overflow = %{
      "contents" => [
        %{"uri" => @skill_md, "text" => "---\nname: pdf-processing\nlimit: 1e9999\n---\n"}
      ]
    }

    assert %{"reason" => "frontmatter_unreadable", "detail" => detail} =
             failure(Skills.verify(dynamic, @skill_md, overflow))

    assert detail =~ "out of range"
  end

  test "reports a very long number in SKILL.md instead of raising" do
    alias Snodo.Skills.ClientTest.LongNumberServer
    alias Snodo.Skills.ClientTest.LongNumberSkill, as: LongNumber

    text = LongNumber.text()
    uri = LongNumber.uri()

    entry = %{
      "uri" => uri,
      "frontmatter" => %{"name" => "long-number", "description" => "d"},
      "resources" => [%{"uri" => uri, "digest" => Skill.digest(text), "size" => byte_size(text)}]
    }

    {:ok, client} = Client.direct(LongNumberServer.runtime())

    assert %{"reason" => "frontmatter_unreadable", "detail" => detail} =
             failure(Skills.load(client, entry))

    assert detail =~ "more than the built-in parser reads"

    result = %{"contents" => [%{"uri" => uri, "text" => text}]}
    assert %{"reason" => "frontmatter_unreadable"} = failure(Skills.verify(entry, uri, result))

    # Inside the size limit, the digit count is what refuses it.
    digits =
      "---\nname: long-number\ndescription: d\ncount: #{String.duplicate("7", 1_001)}\n---\n"

    dynamic = Map.put(entry, "resources", "dynamic")

    assert %{"reason" => "frontmatter_unreadable", "detail" => detail} =
             failure(
               Skills.verify(dynamic, uri, %{"contents" => [%{"uri" => uri, "text" => digits}]})
             )

    assert detail =~ "more than 1000 digits"
  end

  test "reads frontmatter with a configured parser", %{client: client, entry: entry} do
    parser = fn _yaml -> {:ok, entry["frontmatter"]} end
    tampered = put_in(entry, ["frontmatter", "license"], "MIT")

    assert %{"reason" => "frontmatter_mismatch"} = failure(Skills.load(client, tampered))

    assert {:ok, _content} =
             Skills.load(client, tampered,
               frontmatter_parser: fn _yaml -> {:ok, tampered["frontmatter"]} end
             )

    assert {:ok, _content} = Skills.load(client, entry, frontmatter_parser: parser)
  end
end
