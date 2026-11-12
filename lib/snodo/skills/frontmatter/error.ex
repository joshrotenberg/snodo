defmodule Snodo.Skills.Frontmatter.Error do
  @moduledoc """
  A SKILL.md frontmatter block that could not be read.

  `reason` is one of:

    * `:missing` - the file does not begin with a `---` delimited block.
    * `:unsupported` - valid YAML outside the subset `Snodo.Skills.Frontmatter`
      reads, such as a block scalar, an anchor, or a flow mapping. A
      `:frontmatter_parser` that handles full YAML reads it.
    * `:invalid` - the block is not valid YAML, or has a duplicate key.
    * `:too_large` - the block is over a limit of the built-in subset: more
      than 1,048,576 bytes, or a number with more than 1,000 digits.
    * `:not_object` - the block, or the configured parser's result, is not a
      JSON object with string keys.
    * `:parser` - the configured `:frontmatter_parser` returned an error.

  `line` is the line of the file the problem is on, when known.
  """

  @type reason :: :missing | :unsupported | :invalid | :too_large | :not_object | :parser

  @type t :: %__MODULE__{
          reason: reason(),
          line: pos_integer() | nil,
          message: String.t()
        }

  defexception [:reason, :line, :message]
end
