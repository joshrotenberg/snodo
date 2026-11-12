defmodule Snodo.Skills.Skill do
  @moduledoc """
  One skill a `Snodo.Skills` module serves.

    * `:path` - the skill path, such as `"pdf-processing"` or
      `"acme/pdf-processing"`. Its last segment is the skill name.
    * `:name` - the frontmatter `name`.
    * `:uri` - the URI of the skill's SKILL.md, `skill://<path>/SKILL.md`.
    * `:frontmatter` - the SKILL.md frontmatter as a JSON object.
    * `:files` - every file of the skill, SKILL.md first and the rest sorted
      by path, each a map with `:path` (relative to the skill directory),
      `:uri`, `:digest` (`"sha256:"` and 64 lowercase hex characters of the
      file's bytes), `:size` in bytes, `:mime_type`, and `:resource`, the
      generated `Snodo.Resource` module that serves it.
  """

  @type file :: %{
          path: String.t(),
          uri: String.t(),
          digest: String.t(),
          size: non_neg_integer(),
          mime_type: String.t(),
          resource: module() | nil
        }

  @type t :: %__MODULE__{
          path: String.t(),
          name: String.t(),
          uri: String.t(),
          frontmatter: map(),
          files: [file()]
        }

  @enforce_keys [:path, :name, :uri, :frontmatter, :files]
  defstruct [:path, :name, :uri, :frontmatter, :files]

  @doc """
  Returns the skill entry `skills/list` and `skills/get` send: `"uri"`,
  `"frontmatter"`, and `"resources"`, one `{"uri", "digest", "size"}` object
  per file.
  """
  @spec entry(t()) :: map()
  def entry(%__MODULE__{} = skill) do
    %{
      "uri" => skill.uri,
      "frontmatter" => skill.frontmatter,
      "resources" =>
        Enum.map(skill.files, fn file ->
          %{"uri" => file.uri, "digest" => file.digest, "size" => file.size}
        end)
    }
  end

  @doc "Returns the `\"sha256:<hex>\"` digest of `bytes`."
  @spec digest(binary()) :: String.t()
  def digest(bytes) when is_binary(bytes),
    do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
