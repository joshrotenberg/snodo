defmodule Snodo.Skills.FrontmatterTest do
  use ExUnit.Case, async: true

  alias Snodo.Skills.Frontmatter
  alias Snodo.Skills.Frontmatter.Error

  defp parse(yaml), do: Frontmatter.parse("---\n" <> yaml <> "\n---\nBody\n")

  def empty(_yaml), do: {:ok, nil}

  describe "split/1" do
    test "returns the frontmatter text and the body" do
      assert {:ok, "name: a\ndescription: b", "\nBody\n"} =
               Frontmatter.split("---\nname: a\ndescription: b\n---\n\nBody\n")
    end

    test "accepts CRLF line endings, a byte order mark, and a file that ends at the block" do
      assert {:ok, "name: a", ""} = Frontmatter.split("﻿---\r\nname: a\r\n---")
    end

    test "requires an opening line of exactly three dashes" do
      for text <- ["name: a\n", "--- \nname: a\n---\n", "\n---\nname: a\n---\n", "---\nname: a\n"] do
        assert {:error, %Error{reason: :missing, line: 1}} = Frontmatter.split(text)
      end
    end
  end

  describe "the built-in subset" do
    test "reads plain, quoted, and typed scalars" do
      yaml = """
      name: pdf-processing
      description: Extract, fill, and assemble PDF documents # trailing comment
      license: 'Apache-2.0'
      quoted: "tab\\there \\u00e9 \\"q\\""
      single: 'it''s'
      empty:
      tilde: ~
      enabled: true
      disabled: FALSE
      count: 42
      negative: -7
      hex: 0x1F
      octal: 0o17
      ratio: 1.5
      exponent: 1e3
      version: 1.0.0
      url: https://example.com/a#b
      yes_is_a_string: yes\
      """

      assert {:ok, frontmatter} = parse(yaml)

      assert frontmatter == %{
               "name" => "pdf-processing",
               "description" => "Extract, fill, and assemble PDF documents",
               "license" => "Apache-2.0",
               "quoted" => "tab\there é \"q\"",
               "single" => "it's",
               "empty" => nil,
               "tilde" => nil,
               "enabled" => true,
               "disabled" => false,
               "count" => 42,
               "negative" => -7,
               "hex" => 31,
               "octal" => 15,
               "ratio" => 1.5,
               "exponent" => 1000.0,
               "version" => "1.0.0",
               "url" => "https://example.com/a#b",
               "yes_is_a_string" => "yes"
             }
    end

    test "reads flow and block sequences and one nested mapping" do
      yaml = """
      name: a
      allowed-tools: [Read, "Bash(git:*)", 3]
      empty-list: []
      steps:
        - first
        - 'second'
        -
      compact:
      - one
      - two
      metadata:
        author: example-org
        version: "1.0"
        tags: [pdf, forms]
        io.modelcontextprotocol.skills/origin: disk
      "quoted key": value\
      """

      assert {:ok, frontmatter} = parse(yaml)
      assert frontmatter["allowed-tools"] == ["Read", "Bash(git:*)", 3]
      assert frontmatter["empty-list"] == []
      assert frontmatter["steps"] == ["first", "second", nil]
      assert frontmatter["compact"] == ["one", "two"]

      assert frontmatter["metadata"] == %{
               "author" => "example-org",
               "version" => "1.0",
               "tags" => ["pdf", "forms"],
               "io.modelcontextprotocol.skills/origin" => "disk"
             }

      assert frontmatter["quoted key"] == "value"
    end

    test "folds a plain scalar that continues on indented lines" do
      yaml = """
      name: a
      description: Extract text from PDF files
        and fill in forms.
      """

      assert {:ok, %{"description" => "Extract text from PDF files and fill in forms."}} =
               parse(yaml)
    end

    test "skips comments and blank lines" do
      assert {:ok, %{"name" => "a"}} = parse("# leading comment\n\nname: a\n  # indented comment")
      assert {:ok, %{}} = Frontmatter.parse("---\n# only a comment\n---\n")
    end

    test "refuses constructs outside the subset as unsupported, with the line" do
      cases = [
        {"description: |\n  literal", 2, "block scalar"},
        {"description: >-\n  folded", 2, "block scalar"},
        {"base: &anchor value", 2, "anchor"},
        {"copy: *anchor", 2, "alias"},
        {"typed: !!str 5", 2, "tag"},
        {"map: {a: 1}", 2, "flow mapping"},
        {"name: a\nquoted: \"open\n  close\"", 3, "spanning lines"},
        {"list: [a,\n  b]", 2, "spanning lines"},
        {"metadata:\n  outer:\n    inner: 1", 4, "deeper"},
        {"steps:\n  - key: value", 3, "sequence of mappings"},
        {"steps:\n  - - nested", 3, "nested sequence"},
        {"\tname: a", 2, "tab"},
        {"limit: .inf", 2, "JSON"}
      ]

      for {yaml, line, fragment} <- cases do
        assert {:error, %Error{reason: :unsupported, line: ^line, message: message}} =
                 parse(yaml),
               inspect(yaml)

        assert message =~ fragment, "#{inspect(yaml)}: #{message}"
      end
    end

    test "refuses invalid YAML" do
      for yaml <- [
            "name: a\nname: b",
            "name: a: b",
            "name: - item",
            "  name: a",
            "just text",
            "name: \"closed\" trailing",
            "name: @reserved",
            "metadata:\n    a: 1\n  b: 2",
            "name: \"bad \\q escape\""
          ] do
        assert {:error, %Error{reason: :invalid}} = parse(yaml), inspect(yaml)
      end
    end

    test "refuses a frontmatter block that is not a mapping" do
      assert {:error, %Error{reason: :not_object}} = parse("- a\n- b")
    end
  end

  describe ":parser" do
    test "uses a function or a {module, function} pair instead of the subset" do
      parser = fn yaml -> {:ok, %{"raw" => yaml}} end

      assert {:ok, %{"raw" => "x: |\n  y"}} =
               Frontmatter.parse("---\nx: |\n  y\n---\n", parser: parser)

      assert {:ok, %{}} = Frontmatter.parse("---\nx: 1\n---\n", parser: {__MODULE__, :empty})
    end

    test "reports parser errors and non-object results" do
      text = "---\nx: 1\n---\n"

      assert {:error, %Error{reason: :parser}} =
               Frontmatter.parse(text, parser: fn _yaml -> {:error, :boom} end)

      assert {:error, %Error{reason: :parser}} =
               Frontmatter.parse(text, parser: fn _yaml -> raise "boom" end)

      assert {:error, %Error{reason: :not_object}} =
               Frontmatter.parse(text, parser: fn _yaml -> {:ok, ["a"]} end)

      assert {:error, %Error{reason: :not_object}} =
               Frontmatter.parse(text, parser: fn _yaml -> {:ok, %{a: 1}} end)
    end

    test "validates the option" do
      assert Frontmatter.validate_parser!(nil) == nil
      assert_raise ArgumentError, fn -> Frontmatter.validate_parser!(:yaml) end
    end
  end
end
