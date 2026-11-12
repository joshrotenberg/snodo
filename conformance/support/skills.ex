defmodule SnodoTest.Conformance.Skills do
  @moduledoc false
  # The SEP-2640 skills the fixture serves when run.mjs sets
  # MCP_FIXTURE_SKILLS=1: one skill with a subdirectory, so
  # resources/directory/read has an inode/directory child to list.
  use Snodo.Skills, directory: Path.join(__DIR__, "skills")
end
