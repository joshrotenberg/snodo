Code.require_file("mrtr.ex", __DIR__)
Code.require_file("progress.ex", __DIR__)

defmodule MCPEx.Conformance.Tools.SimpleText do
  use MCP.Tool,
    name: "test_simple_text",
    description: "Returns one text content item for the official conformance runner"

  @impl true
  def call(_arguments, _context) do
    {:ok, MCP.Result.text("This is a simple text response for testing.")}
  end
end

defmodule MCPEx.Conformance.Tools.HeaderProbe do
  use MCP.Tool,
    name: "a_header_probe",
    description: "Returns a synchronous result for generic conformance probes"

  @impl true
  def call(_arguments, _context), do: {:ok, MCP.Result.text("Header probe accepted")}
end

defmodule MCPEx.Conformance.Tools.ImageContent do
  use MCP.Tool,
    name: "test_image_content",
    description: "Returns a small PNG image content item for conformance"

  @one_pixel_png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z4p8AAAAASUVORK5CYII="

  @impl true
  def call(_arguments, _context) do
    {:ok,
     MCP.Result.raw(%{
       "content" => [
         %{"type" => "image", "data" => @one_pixel_png, "mimeType" => "image/png"}
       ]
     })}
  end
end

defmodule MCPEx.Conformance.Tools.AudioContent do
  use MCP.Tool,
    name: "test_audio_content",
    description: "Returns a small WAV audio content item for conformance"

  @silent_wav "UklGRiQAAABXQVZFZm10IBAAAAABAAEAQB8AAEAfAAABAAgAZGF0YQAAAAA="

  @impl true
  def call(_arguments, _context) do
    {:ok,
     MCP.Result.raw(%{
       "content" => [
         %{"type" => "audio", "data" => @silent_wav, "mimeType" => "audio/wav"}
       ]
     })}
  end
end

defmodule MCPEx.Conformance.Tools.EmbeddedResource do
  use MCP.Tool,
    name: "test_embedded_resource",
    description: "Returns one embedded text resource for conformance"

  @impl true
  def call(_arguments, _context) do
    {:ok,
     MCP.Result.raw(%{
       "content" => [
         %{
           "type" => "resource",
           "resource" => %{
             "uri" => "test://embedded-resource",
             "mimeType" => "text/plain",
             "text" => "This is an embedded resource content."
           }
         }
       ]
     })}
  end
end

defmodule MCPEx.Conformance.Tools.MixedContent do
  use MCP.Tool,
    name: "test_multiple_content_types",
    description: "Returns text, image, and embedded resource content together"

  @one_pixel_png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z4p8AAAAASUVORK5CYII="

  @impl true
  def call(_arguments, _context) do
    {:ok,
     MCP.Result.raw(%{
       "content" => [
         %{"type" => "text", "text" => "Multiple content types test:"},
         %{"type" => "image", "data" => @one_pixel_png, "mimeType" => "image/png"},
         %{
           "type" => "resource",
           "resource" => %{
             "uri" => "test://mixed-content-resource",
             "mimeType" => "application/json",
             "text" => JSON.encode!(%{"test" => "data", "value" => 123})
           }
         }
       ]
     })}
  end
end

defmodule MCPEx.Conformance.Tools.ErrorHandling do
  use MCP.Tool,
    name: "test_error_handling",
    description: "Returns the tool-level error result expected by conformance"

  @impl true
  def call(_arguments, _context) do
    {:error, "This tool intentionally returns an error for testing"}
  end
end

defmodule MCPEx.Conformance.Tools.JSONSchema2020 do
  use MCP.Tool,
    name: "json_schema_2020_12_tool",
    description: "Tool with JSON Schema 2020-12 features"

  input_schema(%{
    "$schema" => "https://json-schema.org/draft/2020-12/schema",
    "type" => "object",
    "$defs" => %{
      "address" => %{
        "$anchor" => "addressDef",
        "type" => "object",
        "properties" => %{
          "street" => %{"type" => "string"},
          "city" => %{"type" => "string"}
        }
      }
    },
    "properties" => %{
      "name" => %{"type" => "string"},
      "address" => %{"$ref" => "#/$defs/address"},
      "contactMethod" => %{"type" => "string", "enum" => ["phone", "email"]},
      "phone" => %{"type" => "string"},
      "email" => %{"type" => "string"}
    },
    "allOf" => [%{"anyOf" => [%{"required" => ["phone"]}, %{"required" => ["email"]}]}],
    "if" => %{
      "properties" => %{"contactMethod" => %{"const" => "phone"}},
      "required" => ["contactMethod"]
    },
    "then" => %{"required" => ["phone"]},
    "else" => %{"required" => ["email"]},
    "additionalProperties" => false
  })

  @impl true
  def call(_arguments, _context), do: {:ok, MCP.Result.text("schema accepted")}
end

defmodule MCPEx.Conformance.Prompts.Simple do
  use MCP.Prompt,
    name: "test_simple_prompt",
    description: "A simple prompt without arguments"

  @impl true
  def render(_arguments, _context) do
    {:ok,
     MCP.Result.prompt_get(
       MCP.Prompt.message(:user, MCP.Prompt.text("This is a simple test prompt.")),
       description: "Simple conformance prompt"
     )}
  end
end

defmodule MCPEx.Conformance.Prompts.WithArguments do
  use MCP.Prompt,
    name: "test_prompt_with_arguments",
    description: "A prompt that substitutes two arguments",
    arguments: [
      %{"name" => "arg1", "description" => "First test value", "required" => true},
      %{"name" => "arg2", "description" => "Second test value", "required" => true}
    ],
    completion_arguments: ["arg1", "arg2"]

  @impl true
  def render(%{"arg1" => arg1, "arg2" => arg2}, _context) do
    {:ok,
     MCP.Result.prompt_get(
       MCP.Prompt.message(
         :user,
         MCP.Prompt.text("Parameterized prompt values: #{arg1} and #{arg2}.")
       ),
       description: "Parameterized conformance prompt"
     )}
  end

  @impl true
  def complete(%MCP.Completion{value: value}, _context) do
    {:ok, MCP.Result.completion([value], total: 1, has_more: false)}
  end
end

defmodule MCPEx.Conformance.Prompts.WithEmbeddedResource do
  use MCP.Prompt,
    name: "test_prompt_with_embedded_resource",
    description: "A prompt containing an embedded resource",
    arguments: [
      %{"name" => "resourceUri", "description" => "Resource URI", "required" => true}
    ]

  @impl true
  def render(%{"resourceUri" => uri}, _context) do
    resource =
      MCP.Resource.text(uri, "This is embedded resource content.", mime_type: "text/plain")

    {:ok,
     MCP.Result.prompt_get(
       MCP.Prompt.message(:user, MCP.Prompt.embedded_resource(resource)),
       description: "Embedded resource conformance prompt"
     )}
  end
end

defmodule MCPEx.Conformance.Prompts.WithImage do
  use MCP.Prompt,
    name: "test_prompt_with_image",
    description: "A prompt containing image content"

  @one_pixel_png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z4p8AAAAASUVORK5CYII="

  @impl true
  def render(_arguments, _context) do
    {:ok,
     MCP.Result.prompt_get(
       MCP.Prompt.message(:user, MCP.Prompt.image(@one_pixel_png, "image/png")),
       description: "Image conformance prompt"
     )}
  end
end

defmodule MCPEx.Conformance.Resources.StaticText do
  use MCP.Resource,
    uri: "test://static-text",
    name: "static_text",
    description: "Static text resource required by the frozen conformance runner",
    mime_type: "text/plain"

  @impl true
  def read(%{"uri" => uri}, _context) do
    {:ok,
     MCP.Result.resource_read(
       MCP.Resource.text(uri, "This is a static text resource for testing.",
         mime_type: "text/plain"
       )
     )}
  end
end

defmodule MCPEx.Conformance.Resources.StaticBinary do
  use MCP.Resource,
    uri: "test://static-binary",
    name: "static_binary",
    description: "Static binary resource required by the frozen conformance runner",
    mime_type: "application/octet-stream"

  @bytes <<0, 1, 2, 3, 127, 128, 254, 255>>

  @impl true
  def read(%{"uri" => uri}, _context) do
    {:ok,
     MCP.Result.resource_read(
       MCP.Resource.blob(uri, Base.encode64(@bytes), mime_type: "application/octet-stream")
     )}
  end
end

defmodule MCPEx.Conformance.Resources.TemplateData do
  use MCP.Resource,
    uri_template: "test://template/{id}/data",
    name: "template_data",
    description: "Parameterized resource required by the frozen conformance runner",
    mime_type: "text/plain"

  @prefix "test://template/"
  @suffix "/data"

  @impl true
  def matches?(uri) when is_binary(uri), do: match?({:ok, _id}, extract_id(uri))

  @impl true
  def read(%{"uri" => uri}, _context) do
    with {:ok, id} <- extract_id(uri) do
      {:ok,
       MCP.Result.resource_read(
         MCP.Resource.text(uri, "Template resource data for id #{id}", mime_type: "text/plain")
       )}
    end
  end

  defp extract_id(uri) do
    with true <- String.starts_with?(uri, @prefix),
         true <- String.ends_with?(uri, @suffix),
         id <- String.slice(uri, byte_size(@prefix), byte_size(uri)),
         id <- String.slice(id, 0, byte_size(id) - byte_size(@suffix)),
         true <- id != "" and not String.contains?(id, "/") do
      {:ok, id}
    else
      _no_match -> :error
    end
  end
end

defmodule MCPEx.Conformance.Fixture do
  alias MCP.Protocol.V2026_07_28
  alias MCP.Router
  alias MCP.Server.Runtime
  alias MCPEx.Conformance.MRTR, as: MRTRFixture
  alias MCPEx.Conformance.Progress.Tool, as: ProgressTool
  alias MCPEx.Conformance.Prompts.Simple
  alias MCPEx.Conformance.Prompts.WithArguments
  alias MCPEx.Conformance.Prompts.WithEmbeddedResource
  alias MCPEx.Conformance.Prompts.WithImage
  alias MCPEx.Conformance.Resources.StaticBinary
  alias MCPEx.Conformance.Resources.StaticText
  alias MCPEx.Conformance.Resources.TemplateData
  alias MCPEx.Conformance.Tasks, as: TasksFixture
  alias MCPEx.Conformance.Tools.AudioContent
  alias MCPEx.Conformance.Tools.EmbeddedResource
  alias MCPEx.Conformance.Tools.ErrorHandling
  alias MCPEx.Conformance.Tools.HeaderProbe
  alias MCPEx.Conformance.Tools.ImageContent
  alias MCPEx.Conformance.Tools.JSONSchema2020
  alias MCPEx.Conformance.Tools.MixedContent
  alias MCPEx.Conformance.Tools.SimpleText

  @tools [
           HeaderProbe,
           SimpleText,
           ImageContent,
           AudioContent,
           EmbeddedResource,
           MixedContent,
           ErrorHandling,
           JSONSchema2020,
           ProgressTool
         ] ++ TasksFixture.tools() ++ MRTRFixture.tools()

  @resources [StaticText, StaticBinary, TemplateData] ++ MRTRFixture.resources()
  @prompts [Simple, WithArguments, WithEmbeddedResource, WithImage] ++ MRTRFixture.prompts()

  def runtime do
    MCPEx.Conformance.MRTR.Workflow.configure()

    router =
      @tools
      |> Enum.reduce(Router.new(), &Router.register_tool(&2, &1))
      |> then(
        &Enum.reduce(@prompts, &1, fn prompt, acc ->
          Router.register_prompt(acc, prompt)
        end)
      )
      |> then(
        &Enum.reduce(@resources, &1, fn resource, acc ->
          Router.register_resource(acc, resource)
        end)
      )

    capabilities =
      TasksFixture.capabilities()
      |> Map.put("completions", %{})
      |> Map.put("prompts", %{})
      |> Map.put("resources", %{})

    Runtime.new(
      router: router,
      protocols: [V2026_07_28],
      extensions: [TasksFixture.extension()],
      server_info: %{"name" => "mcp-ex-conformance", "version" => "0.1.0"},
      capabilities: capabilities,
      tools_cache: [ttl_ms: 0, scope: "private"],
      prompts_cache: [ttl_ms: 0, scope: "private"],
      resources_cache: [ttl_ms: 0, scope: "private"]
    )
  end
end
