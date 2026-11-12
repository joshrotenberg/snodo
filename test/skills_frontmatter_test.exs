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

    test "refuses a number outside the double range instead of raising" do
      for yaml <- ["value: 1e9999", "value: -1e9999", "values: [1, 1e9999]"] do
        assert {:error, %Error{reason: :unsupported, line: 2, message: message}} = parse(yaml)
        assert message =~ "out of range"
      end

      assert {:ok, %{"value" => 1.0e300}} = parse("value: 1e300")
    end

    test "refuses a number with more than 1,000 digits instead of raising" do
      # 1,300,000 digits raise SystemLimitError in String.to_integer/1; the
      # size limit refuses the block before any conversion.
      huge = String.duplicate("7", 1_300_000)

      for yaml <- ["n: #{huge}", "n: 0x#{huge}", "n: [#{huge}]", "n: #{huge}.5"] do
        assert {:error, %Error{reason: :too_large, line: nil, message: message}} = parse(yaml)
        assert message =~ "more than the built-in parser reads (1048576)"
      end

      long = String.duplicate("7", 1_001)

      for yaml <- [
            "n: #{long}",
            "n: -#{long}",
            "n: 0x#{long}",
            "n: 0o#{long}",
            "n: #{long}.5",
            "n: 1.#{long}e3",
            "n: [1, #{long}]",
            "n:\n  - #{long}",
            "metadata:\n  n: #{long}"
          ] do
        assert {:error, %Error{reason: :too_large, message: message}} = parse(yaml), yaml
        assert message =~ "more than 1000 digits"
      end

      exact = String.duplicate("7", 1_000)
      assert {:ok, %{"n" => n}} = parse("n: #{exact}")
      assert n == String.to_integer(exact)
      assert {:ok, %{"n" => "#{long}x"}} == parse("n: #{long}x")
    end

    test "parses a long flow sequence in one pass" do
      # 300,000 items: about 40,000 seconds of CPU with a scan of the rest of
      # the line per item, well under a second with one pass.
      items = List.duplicate("a", 300_000)
      yaml = "allowed-tools: [" <> Enum.join(items, ",") <> "]"
      assert byte_size(yaml) < 1_048_576
      assert {:ok, %{"allowed-tools" => ^items}} = parse(yaml)

      quoted = List.duplicate("\"a\"", 200_000)
      assert {:ok, %{"q" => list}} = parse("q: [" <> Enum.join(quoted, ", ") <> "]")
      assert length(list) == 200_000
    end

    test "refuses frontmatter over 1 MiB" do
      yaml = "tools: [" <> String.duplicate("a,", 524_288) <> "a]"
      assert byte_size(yaml) > 1_048_576

      assert {:error, %Error{reason: :too_large, line: nil}} = parse(yaml)
      assert {:error, %Error{reason: :too_large}} = Frontmatter.decode(yaml)

      # A configured parser is not limited.
      assert {:ok, %{"size" => size}} =
               Frontmatter.parse("---\n" <> yaml <> "\n---\n",
                 parser: fn text -> {:ok, %{"size" => byte_size(text)}} end
               )

      assert size == byte_size(yaml)
    end

    test "trims only spaces and tabs, as YAML does" do
      nbsp = <<0xA0::utf8>>
      ideographic = <<0x3000::utf8>>

      assert {:ok, %{"x" => "value" <> ^nbsp}} = parse("x: value" <> nbsp)
      assert {:ok, %{"x" => ^nbsp <> "value"}} = parse("x: " <> nbsp <> "value")
      assert {:ok, %{"x" => "12" <> ^nbsp}} = parse("x: 12" <> nbsp)
      assert {:ok, %{"x" => "true" <> ^ideographic}} = parse("x: true" <> ideographic)
      assert {:ok, %{("name" <> ^nbsp) => "a"}} = parse("name" <> nbsp <> ": a")
      assert {:ok, %{"x" => [^nbsp <> "a" <> ^nbsp, "b"]}} = parse("x: [#{nbsp}a#{nbsp}, b]")
      assert {:ok, %{"x" => [^nbsp <> "a"]}} = parse("x:\n  - #{nbsp}a")

      assert {:error, %Error{reason: :invalid}} = parse("x: \"q\"" <> nbsp)

      # Spaces and tabs are still trimmed.
      assert {:ok, %{"x" => "value", "y" => [1, 2]}} = parse("x: \t value \t\ny: [ 1\t, 2 ]\t")
    end

    test "breaks lines at a lone carriage return, as YAML does" do
      assert {:ok, %{"a" => 1, "b" => 2}} = parse("a: 1\rb: 2")
      assert {:ok, %{"a" => 1, "b" => 2}} = parse("a: 1\r\nb: 2")
    end

    test "refuses a blank or comment line inside a multi-line plain scalar" do
      assert {:error, %Error{reason: :unsupported, line: 4}} =
               parse("description: first\n\n  second")

      assert {:error, %Error{reason: :unsupported, line: 4}} =
               parse("description: first\n  # note\n  second")

      assert {:ok, %{"description" => "first second", "next" => 1}} =
               parse("description: first\n  second\n\nnext: 1")

      assert {:ok, %{"steps" => ["a", "b"]}} = parse("steps:\n  - a\n\n  - b")
    end

    test "refuses a comment inside a flow sequence" do
      for yaml <- [
            "tools: [read # hidden, write]",
            "tools: [\"read\" # hidden, write]",
            "tools: [read, # c]"
          ] do
        assert {:error, %Error{reason: :unsupported, message: message}} = parse(yaml), yaml
        assert message =~ "comment inside a flow sequence"
      end

      assert {:ok, %{"tools" => ["read", "write#1"]}} = parse("tools: [read, write#1] # trailing")
    end

    test "requires exactly the hexadecimal digits of an escape" do
      for escape <- ["\\u+041", "\\u-041", "\\x+4", "\\u 041", "\\U+0000041"] do
        assert {:error, %Error{reason: :invalid, message: message}} =
                 parse("x: \"#{escape}\""),
               escape

        assert message =~ "hexadecimal escape"
      end

      assert {:ok, %{"x" => "AAA"}} = parse("x: \"\\x41\\u0041\\U00000041\"")
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
