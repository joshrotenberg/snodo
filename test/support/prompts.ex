defmodule MCPEx.TestPrompts.PackageAnalysis do
  use MCP.Prompt,
    name: "package_analysis",
    title: "Analyze a Hex package",
    description: "Builds a guided package analysis workflow",
    arguments: [
      %{
        "name" => "name",
        "title" => "Package",
        "description" => "Package name on hex.pm",
        "required" => true
      },
      %{"name" => "focus", "description" => "Optional analysis focus"}
    ],
    icons: [
      %{
        "src" => "https://example.test/package.png",
        "mimeType" => "image/png",
        "sizes" => ["32x32"],
        "theme" => "light"
      }
    ],
    metadata: %{"com.example/prompt" => %{"category" => "analysis"}}

  @impl true
  def render(%{"name" => name} = arguments, context) do
    focus = Map.get(arguments, "focus", "health, adoption, and risk")

    messages = [
      MCP.Prompt.message(
        :user,
        MCP.Prompt.text("Analyze #{name}, focusing on #{focus}.",
          annotations: %{"audience" => ["assistant"], "priority" => 0.9},
          metadata: %{"com.example/content" => "request"}
        )
      ),
      MCP.Prompt.message(
        :assistant,
        MCP.Prompt.text("I will use package tools and report the evidence.")
      )
    ]

    {:ok,
     MCP.Result.prompt_get(messages,
       description: "Analysis workflow for #{name}",
       metadata: %{
         "com.example/result" => %{
           "requestId" => context.request_id,
           "request" => context.metadata["com.example/request"]
         }
       }
     )}
  end
end

defmodule MCPEx.TestPrompts.MediaReview do
  use MCP.Prompt,
    name: "media_review",
    description: "Returns the non-text prompt content blocks",
    arguments: [%{"name" => "uri", "required" => true}]

  @one_pixel_png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z4p8AAAAASUVORK5CYII="
  @silent_wav "UklGRiQAAABXQVZFZm10IBAAAAABAAEAQB8AAEAfAAABAAgAZGF0YQAAAAA="

  @impl true
  def render(%{"uri" => uri}, _context) do
    messages = [
      MCP.Prompt.message(:user, MCP.Prompt.image(@one_pixel_png, "image/png")),
      MCP.Prompt.message(:assistant, MCP.Prompt.audio(@silent_wav, "audio/wav")),
      MCP.Prompt.message(
        :user,
        MCP.Prompt.embedded_resource(MCP.Resource.text(uri, "embedded package notes"))
      ),
      MCP.Prompt.message(:assistant, MCP.Prompt.resource_link(uri, "package_notes"))
    ]

    {:ok, MCP.Result.prompt_get(messages)}
  end
end

defmodule MCPEx.TestPrompts.DeclaredError do
  use MCP.Prompt,
    name: "declared_error",
    description: "Returns an explicit protocol error"

  @impl true
  def render(_arguments, _context) do
    {:error, MCP.Error.invalid_params("Prompt access denied")}
  end
end

defmodule MCPEx.TestPrompts.InvalidContent do
  use MCP.Prompt,
    name: "invalid_content",
    description: "Returns invalid content for failure-boundary coverage"

  @impl true
  def render(_arguments, _context) do
    {:ok,
     MCP.Result.prompt_get([
       %{"role" => "user", "content" => %{"type" => "image", "data" => "not-base64"}}
     ])}
  end
end

defmodule MCPEx.TestPrompts.WrongKind do
  use MCP.Prompt,
    name: "wrong_kind",
    description: "Returns the wrong protocol-neutral result kind"

  @impl true
  def render(_arguments, _context), do: {:ok, MCP.Result.text("wrong")}
end
