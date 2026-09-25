defmodule SnodoTest.TestPrompts.PackageAnalysis do
  use Snodo.Prompt,
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
      Snodo.Prompt.message(
        :user,
        Snodo.Prompt.text("Analyze #{name}, focusing on #{focus}.",
          annotations: %{"audience" => ["assistant"], "priority" => 0.9},
          metadata: %{"com.example/content" => "request"}
        )
      ),
      Snodo.Prompt.message(
        :assistant,
        Snodo.Prompt.text("I will use package tools and report the evidence.")
      )
    ]

    {:ok,
     Snodo.Result.prompt_get(messages,
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

defmodule SnodoTest.TestPrompts.MediaReview do
  use Snodo.Prompt,
    name: "media_review",
    description: "Returns the non-text prompt content blocks",
    arguments: [%{"name" => "uri", "required" => true}]

  @one_pixel_png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z4p8AAAAASUVORK5CYII="
  @silent_wav "UklGRiQAAABXQVZFZm10IBAAAAABAAEAQB8AAEAfAAABAAgAZGF0YQAAAAA="

  @impl true
  def render(%{"uri" => uri}, _context) do
    messages = [
      Snodo.Prompt.message(:user, Snodo.Prompt.image(@one_pixel_png, "image/png")),
      Snodo.Prompt.message(:assistant, Snodo.Prompt.audio(@silent_wav, "audio/wav")),
      Snodo.Prompt.message(
        :user,
        Snodo.Prompt.embedded_resource(Snodo.Resource.text(uri, "embedded package notes"))
      ),
      Snodo.Prompt.message(:assistant, Snodo.Prompt.resource_link(uri, "package_notes"))
    ]

    {:ok, Snodo.Result.prompt_get(messages)}
  end
end

defmodule SnodoTest.TestPrompts.DeclaredError do
  use Snodo.Prompt,
    name: "declared_error",
    description: "Returns an explicit protocol error"

  @impl true
  def render(_arguments, _context) do
    {:error, Snodo.Error.invalid_params("Prompt access denied")}
  end
end

defmodule SnodoTest.TestPrompts.InvalidContent do
  use Snodo.Prompt,
    name: "invalid_content",
    description: "Returns invalid content for failure-boundary coverage"

  @impl true
  def render(_arguments, _context) do
    {:ok,
     Snodo.Result.prompt_get([
       %{"role" => "user", "content" => %{"type" => "image", "data" => "not-base64"}}
     ])}
  end
end

defmodule SnodoTest.TestPrompts.WrongKind do
  use Snodo.Prompt,
    name: "wrong_kind",
    description: "Returns the wrong protocol-neutral result kind"

  @impl true
  def render(_arguments, _context), do: {:ok, Snodo.Result.text("wrong")}
end
