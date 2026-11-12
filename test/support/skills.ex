defmodule SnodoTest.Skills do
  @moduledoc false
  # Two skills from test/fixtures/skills and one supplied as an entry, with a
  # binary file and a small page size so pagination is exercised.

  use Snodo.Skills,
    directory: "test/fixtures/skills",
    entries: [
      [
        path: "inline-tool",
        files: %{
          "SKILL.md" =>
            "---\nname: inline-tool\ndescription: Supplied by the application\n---\nBody\n",
          "data/blob.bin" => <<0, 159, 146, 150, 255>>
        }
      ]
    ],
    page_size: 2,
    directory_page_size: 2
end

defmodule SnodoTest.SkillsServer do
  @moduledoc false

  use Snodo.Server,
    name: "skills-test",
    version: "1.0.0",
    extensions: [SnodoTest.Skills],
    capabilities: SnodoTest.Skills.capabilities()

  for file <- SnodoTest.Skills.resources(), do: resource(file)
end
