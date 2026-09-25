defmodule MCP.SimpleComponentsTest do
  use ExUnit.Case, async: true

  alias MCP.Client
  alias MCP.Error
  alias MCP.Resource
  alias MCP.Result

  defmodule SimpleJSON do
    use MCP.Resource.Simple,
      uri: "test://simple/json",
      name: "simple_json",
      description: "A JSON value returned bare"

    @impl true
    def read(_params, _context), do: {:ok, %{"groups" => ["web", "data"]}}
  end

  defmodule RawJSON do
    use MCP.Resource,
      uri: "test://simple/json",
      name: "simple_json",
      description: "A JSON value returned bare"

    @impl true
    def read(%{"uri" => uri}, _context) do
      {:ok, Result.resource_read(Resource.json(uri, %{"groups" => ["web", "data"]}))}
    end
  end

  defmodule SimpleMarkdown do
    use MCP.Resource.Simple,
      uri: "test://simple/readme",
      name: "readme",
      mime_type: "text/markdown"

    @impl true
    def read(_params, _context), do: {:ok, "# Readme\n"}
  end

  defmodule SimpleNote do
    use MCP.Resource.Simple, uri_template: "test://notes/{id}", name: "note"

    @impl true
    def read(%{"id" => "missing"}, _context), do: {:error, Error.invalid_params("No such note")}
    def read(%{"id" => "atoms"}, _context), do: {:ok, %{atom: "keys"}}

    def read(%{"id" => "blob", "uri" => uri}, _context),
      do: {:ok, Result.resource_read(Resource.blob(uri, Base.encode64("bytes")))}

    def read(%{"id" => id}, _context), do: {:ok, "note #{id}"}
  end

  defmodule SimpleReview do
    use MCP.Prompt.Simple, name: "review", title: "Review", description: "Review a package"

    argument("name", required: true, description: "Package name", title: "Package")
    argument("focus", description: "What to focus on")

    @impl true
    def render(%{"name" => "conversation"}, _context) do
      {:ok,
       [
         MCP.Prompt.message(:user, MCP.Prompt.text("Hi")),
         MCP.Prompt.message(:assistant, MCP.Prompt.text("Hello"))
       ]}
    end

    def render(%{"name" => "described"}, _context) do
      {:ok, Result.prompt_get(MCP.Prompt.message(:user, MCP.Prompt.text("x")), description: "d")}
    end

    def render(%{"name" => "refused"}, _context), do: {:error, Error.invalid_params("refused")}

    def render(%{"name" => name} = arguments, _context) do
      {:ok, "Review #{name}, focusing on #{arguments["focus"] || "quality"}."}
    end
  end

  defmodule RawReview do
    use MCP.Prompt,
      name: "review",
      title: "Review",
      description: "Review a package",
      arguments: [
        %{
          "name" => "name",
          "required" => true,
          "description" => "Package name",
          "title" => "Package"
        },
        %{"name" => "focus", "description" => "What to focus on"}
      ]

    @impl true
    def render(_arguments, _context), do: {:ok, Result.prompt_get([])}
  end

  defmodule InlineServer do
    use MCP.Server, name: "inline-server", version: "0.1.0"

    alias MCP.Result, as: R

    tool "greet", description: "Create a greeting", additional_properties: false do
      argument("name", :string, required: true)

      @impl true
      def call(%{"name" => name}, _context), do: {:ok, R.text(greeting(name))}

      defp greeting(name), do: "Hello, #{name}!"
    end

    tool "structured.echo" do
      argument("value", :object)

      @impl true
      def call(%{"value" => value}, _context), do: {:ok, value}
    end

    resource "toolbox_groups", uri: "toolbox://groups", mime_type: "application/json" do
      @impl true
      def read(_params, _context), do: {:ok, %{"groups" => ["web", "data"]}}
    end

    prompt "review", description: "Review a package" do
      argument("name", required: true)

      @impl true
      def render(%{"name" => name}, _context), do: {:ok, "Review #{name}."}
    end

    tool(MCPEx.TestTools.Echo)
  end

  defmodule ModuleServer do
    use MCP.Server, name: "inline-server", version: "0.1.0"

    defmodule Greet do
      use MCP.Tool.Simple,
        name: "greet",
        description: "Create a greeting",
        additional_properties: false

      argument("name", :string, required: true)

      @impl true
      def call(%{"name" => name}, _context), do: {:ok, Result.text("Hello, #{name}!")}
    end

    defmodule StructuredEcho do
      use MCP.Tool.Simple, name: "structured.echo"
      argument("value", :object)

      @impl true
      def call(%{"value" => value}, _context), do: {:ok, value}
    end

    defmodule Groups do
      use MCP.Resource.Simple,
        uri: "toolbox://groups",
        name: "toolbox_groups",
        mime_type: "application/json"

      @impl true
      def read(_params, _context), do: {:ok, %{"groups" => ["web", "data"]}}
    end

    defmodule Review do
      use MCP.Prompt.Simple, name: "review", description: "Review a package"
      argument("name", required: true)

      @impl true
      def render(%{"name" => name}, _context), do: {:ok, "Review #{name}."}
    end

    tool(Greet)
    tool(StructuredEcho)
    resource(Groups)
    prompt(Review)
    tool(MCPEx.TestTools.Echo)
  end

  defp client(opts) do
    {:ok, client} = opts |> MCPEx.TestFixtures.runtime() |> Client.direct()
    client
  end

  describe "MCP.Resource.Simple" do
    test "has the same definition as the equivalent MCP.Resource and reads the same" do
      assert SimpleJSON.definition() == RawJSON.definition()

      {:ok, simple} = Client.read_resource(client(resources: [SimpleJSON]), "test://simple/json")
      {:ok, raw} = Client.read_resource(client(resources: [RawJSON]), "test://simple/json")
      assert simple == raw

      assert [%{"mimeType" => "application/json", "text" => ~s({"groups":["web","data"]})}] =
               simple["contents"]
    end

    test "a binary is text at the requested URI with the declared MIME type" do
      client = client(resources: [SimpleMarkdown, SimpleNote])

      assert {:ok, %{"contents" => [markdown]}} =
               Client.read_resource(client, "test://simple/readme")

      assert markdown == %{
               "uri" => "test://simple/readme",
               "mimeType" => "text/markdown",
               "text" => "# Readme\n"
             }

      assert {:ok, %{"contents" => [note]}} = Client.read_resource(client, "test://notes/7")
      assert note == %{"uri" => "test://notes/7", "text" => "note 7"}
    end

    test "results and errors pass through, and a non-JSON value fails the read" do
      client = client(resources: [SimpleNote])

      assert {:ok, %{"contents" => [%{"blob" => blob}]}} =
               Client.read_resource(client, "test://notes/blob")

      assert Base.decode64!(blob) == "bytes"

      assert {:error, %Error{code: -32_602, message: "No such note"}} =
               Client.read_resource(client, "test://notes/missing")

      assert {:error, %Error{code: -32_603}} = Client.read_resource(client, "test://notes/atoms")
    end

    test "a module without read/2 does not compile" do
      source = """
      defmodule MCP.SimpleComponentsTest.NoRead do
        use MCP.Resource.Simple, uri: "test://no-read", name: "no_read"
      end
      """

      assert_raise CompileError, ~r/does not define read\/2/, fn ->
        Code.compile_string(source)
      end
    end
  end

  describe "MCP.Prompt.Simple" do
    test "argument/2 builds the same definition as a hand-written argument list" do
      assert SimpleReview.definition() == RawReview.definition()
    end

    test "a binary is one user message and message lists pass through" do
      client = client(prompts: [SimpleReview])

      assert {:ok, %{"messages" => [message]}} =
               Client.get_prompt(client, "review", %{"name" => "plug"})

      assert message == %{
               "role" => "user",
               "content" => %{"type" => "text", "text" => "Review plug, focusing on quality."}
             }

      assert {:ok, %{"messages" => [%{"role" => "user"}, %{"role" => "assistant"}]}} =
               Client.get_prompt(client, "review", %{"name" => "conversation"})

      assert {:ok, %{"description" => "d"}} =
               Client.get_prompt(client, "review", %{"name" => "described"})

      assert {:error, %Error{code: -32_602, message: "refused"}} =
               Client.get_prompt(client, "review", %{"name" => "refused"})
    end

    test "required arguments are enforced by the router before render/2" do
      assert {:error, %Error{code: -32_602, data: %{"missing" => ["name"]}}} =
               Client.get_prompt(client(prompts: [SimpleReview]), "review", %{})
    end

    test "invalid declarations do not compile" do
      cases = [
        {~r/received unknown options: \[:default\]/,
         ~s(argument "name", default: "x"\n  def render(_a, _c\), do: {:ok, "x"})},
        {~r/declares arguments with argument\/2/, :arguments_option},
        {~r/argument names must be unique/,
         ~s(argument "name"\n  argument "name"\n  def render(_a, _c\), do: {:ok, "x"})},
        {~r/does not define render\/2/, ~s(argument "name")}
      ]

      for {{message, body}, index} <- Enum.with_index(cases) do
        source =
          case body do
            :arguments_option ->
              """
              defmodule MCP.SimpleComponentsTest.BadPrompt#{index} do
                use MCP.Prompt.Simple, name: "bad", arguments: []
                def render(_arguments, _context), do: {:ok, "x"}
              end
              """

            body ->
              """
              defmodule MCP.SimpleComponentsTest.BadPrompt#{index} do
                use MCP.Prompt.Simple, name: "bad"
                #{body}
              end
              """
          end

        assert_raise CompileError, message, fn -> Code.compile_string(source) end
      end
    end
  end

  describe "inline components" do
    test "generate named modules that list exactly like module components" do
      assert Code.ensure_loaded?(InlineServer.Tools.Greet)
      assert Code.ensure_loaded?(InlineServer.Tools.StructuredEcho)
      assert Code.ensure_loaded?(InlineServer.Resources.ToolboxGroups)
      assert Code.ensure_loaded?(InlineServer.Prompts.Review)

      {:ok, inline} = Client.direct(InlineServer.runtime())
      {:ok, modules} = Client.direct(ModuleServer.runtime())

      for list <- [&Client.list_tools/1, &Client.list_resources/1, &Client.list_prompts/1] do
        assert list.(inline) == list.(modules)
      end

      assert {:ok, tools} = Client.list_tools(inline)
      assert Enum.map(tools, & &1["name"]) == ["echo", "greet", "structured.echo"]
    end

    test "inline and module components serve requests side by side" do
      {:ok, client} = Client.direct(InlineServer.runtime())

      assert {:ok, %{"content" => [%{"text" => "Hello, Ada!"}]}} =
               Client.call_tool(client, "greet", %{"name" => "Ada"})

      assert {:ok, %{"structuredContent" => %{"a" => 1}}} =
               Client.call_tool(client, "structured.echo", %{"value" => %{"a" => 1}})

      assert {:ok, %{"content" => [%{"text" => "from a module"}]}} =
               Client.call_tool(client, "echo", %{"text" => "from a module"})

      assert {:ok, %{"contents" => [%{"text" => ~s({"groups":["web","data"]})}]}} =
               Client.read_resource(client, "toolbox://groups")

      assert {:ok, %{"messages" => [%{"content" => %{"text" => "Review plug."}}]}} =
               Client.get_prompt(client, "review", %{"name" => "plug"})
    end

    test "names that map to the same module, a :name option, and a missing block do not compile" do
      cases = [
        {~r/"get-info" and "get_info" would both define/,
         """
         tool "get-info" do
           def call(_a, _c), do: {:ok, "a"}
         end

         tool "get_info" do
           def call(_a, _c), do: {:ok, "b"}
         end
         """},
        {~r/takes its name from the first argument/,
         """
         tool "named", name: "other" do
           def call(_a, _c), do: {:ok, "a"}
         end
         """},
        {~r/needs options and a do block/, ~s(prompt "no_block", description: "x")}
      ]

      for {{message, body}, index} <- Enum.with_index(cases) do
        source = """
        defmodule MCP.SimpleComponentsTest.BadServer#{index} do
          use MCP.Server, name: "bad", version: "1"
          #{body}
        end
        """

        assert_raise CompileError, message, fn -> Code.compile_string(source) end
      end
    end
  end
end
