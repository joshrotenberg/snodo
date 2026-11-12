# Serves the skill directory in examples/support/skills through the Skills
# extension (io.modelcontextprotocol/skills), then lists, loads, and reads it
# with Snodo.Skills.Client, which verifies every file against the listed
# digest and size before using it.

defmodule Examples.Skills.Catalog do
  @moduledoc false
  use Snodo.Skills, directory: Path.join(__DIR__, "support/skills")
end

defmodule Examples.Skills.Server do
  @moduledoc false
  use Snodo.Server,
    name: "skills-example",
    version: "1.0.0",
    extensions: [Examples.Skills.Catalog],
    capabilities: Examples.Skills.Catalog.capabilities()

  # Each skill file is an ordinary resource.
  for file <- Examples.Skills.Catalog.resources(), do: resource(file)
end

defmodule Examples.Skills.Runner do
  @moduledoc false

  alias Examples.Skills.Server
  alias Snodo.Client
  alias Snodo.Skills.Client, as: Skills

  @forms "skill://pdf-processing/references/FORMS.md"

  def run(args) do
    check? = check_mode!(args)

    # A host that uses skills declares the extension.
    {:ok, host} = Client.direct(Server.runtime(), client_capabilities: Skills.capabilities())

    # Listing reads no files.
    {:ok, [entry]} = Skills.list(host)
    ensure(entry["uri"] == "skill://pdf-processing/SKILL.md", "skill URI")
    ensure(length(entry["resources"]) == 2, "two files")

    {:ok, skill_md} = Skills.load(host, entry)
    ensure(String.starts_with?(skill_md["text"], "---\nname: pdf-processing"), "SKILL.md")

    {:ok, forms} = Skills.read(host, entry, @forms)
    ensure(String.starts_with?(forms["text"], "# Filling forms"), "FORMS.md")

    {:ok, %{"resources" => children}} =
      Client.request(host, "resources/directory/read", %{"uri" => "skill://pdf-processing"})

    ensure(
      Enum.map(children, &{&1["name"], &1["mimeType"]}) == [
        {"SKILL.md", "text/markdown"},
        {"references", "inode/directory"}
      ],
      "directory listing"
    )

    # An entry whose digest does not match what the server sends is refused.
    tampered =
      update_in(entry, ["resources"], fn resources ->
        Enum.map(resources, fn
          %{"uri" => @forms} = file ->
            %{file | "digest" => "sha256:" <> String.duplicate("0", 64)}

          file ->
            file
        end)
      end)

    {:error, refused} = Skills.read(host, tampered, @forms)
    ensure(refused.data["reason"] == "digest_mismatch", "digest check")

    # A client without the extension can still read the files as resources,
    # but the skills methods need the declaration.
    {:ok, plain} = Client.direct(Server.runtime())
    {:error, missing} = Skills.list(plain)
    ensure(missing.code == -32_021, "missing capability")
    {:ok, %{"contents" => [_content]}} = Client.read_resource(plain, @forms)

    if check? do
      IO.puts("36_skills: ok")
    else
      IO.puts("skill: #{entry["frontmatter"]["name"]} - #{entry["frontmatter"]["description"]}")

      for file <- entry["resources"] do
        IO.puts("  #{file["uri"]} #{file["size"]} bytes #{file["digest"]}")
      end

      IO.puts("directory: #{Enum.map_join(children, ", ", & &1["name"])}")
      IO.puts("tampered digest: #{refused.message}")
      IO.puts("without the extension: #{missing.message}")
    end
  end

  defp ensure(true, _label), do: :ok
  defp ensure(false, label), do: raise("check failed: #{label}")

  defp check_mode!([]), do: false
  defp check_mode!(["--check"]), do: true

  defp check_mode!(_arguments),
    do: raise("usage: mix run examples/36_skills.exs [--check]")
end

Examples.Skills.Runner.run(System.argv())
