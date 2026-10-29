# Tools and the subscribable resource the official runner calls on an
# initialize-era session. They return input requests like any 2026-07-28
# handler; on a session the transport sends them to the client as
# server-to-client requests and calls the tool again with the answers.

defmodule SnodoTest.Conformance.Sessions do
  @moduledoc false

  # The fixture server starts this hub for the legacy profile; resources/subscribe
  # and list changes on a session read from it.
  @hub SnodoTest.Conformance.SessionHub

  def hub, do: @hub

  def tools do
    [
      SnodoTest.Conformance.Sessions.Sampling,
      SnodoTest.Conformance.Sessions.Elicitation,
      SnodoTest.Conformance.Sessions.Defaults,
      SnodoTest.Conformance.Sessions.Enums
    ]
  end

  def resources, do: [SnodoTest.Conformance.Sessions.Watched]

  # Elicited and sampled values are client input, echoed only for the runner.
  def elicited(context, id, request, label) do
    case Snodo.Elicitation.response(context, id, request) do
      :missing ->
        {:ok, Snodo.Result.input_required(input_requests: %{id => request})}

      {:ok, response} ->
        content = JSON.encode!(Map.get(response, "content", %{}))
        {:ok, Snodo.Result.text("#{label}: action=#{response["action"]}, content=#{content}")}

      {:error, error} ->
        {:error, error}
    end
  end
end

defmodule SnodoTest.Conformance.Sessions.Sampling do
  @moduledoc false

  use Snodo.Tool,
    name: "test_sampling",
    description: "Asks the client to sample a reply to the prompt"

  alias Snodo.Prompt
  alias Snodo.Result
  alias Snodo.Sampling

  input_schema(%{
    "type" => "object",
    "properties" => %{"prompt" => %{"type" => "string"}},
    "required" => ["prompt"]
  })

  @impl true
  def call(%{"prompt" => prompt}, context) do
    request =
      Sampling.create_message([Prompt.message(:user, Prompt.text(prompt))], max_tokens: 100)

    case Sampling.response(context, "reply", request) do
      :missing ->
        {:ok, Result.input_required(input_requests: %{"reply" => request})}

      {:ok, %{"content" => content}} ->
        text =
          content
          |> List.wrap()
          |> Enum.map_join(" ", fn
            %{"type" => "text", "text" => text} -> text
            %{"type" => type} -> "[#{type}]"
          end)

        {:ok, Result.text("LLM response: " <> String.slice(text, 0, 200))}

      {:error, error} ->
        {:error, error}
    end
  end
end

defmodule SnodoTest.Conformance.Sessions.Elicitation do
  @moduledoc false

  use Snodo.Tool,
    name: "test_elicitation",
    description: "Asks the user for a username and an email address"

  alias SnodoTest.Conformance.Sessions

  input_schema(%{
    "type" => "object",
    "properties" => %{"message" => %{"type" => "string"}},
    "required" => ["message"]
  })

  @impl true
  def call(%{"message" => message}, context) do
    request =
      Snodo.Elicitation.form(message, %{
        "type" => "object",
        "properties" => %{
          "username" => %{"type" => "string", "description" => "User's response"},
          "email" => %{"type" => "string", "description" => "User's email address"}
        },
        "required" => ["username", "email"]
      })

    Sessions.elicited(context, "user", request, "User response")
  end
end

defmodule SnodoTest.Conformance.Sessions.Defaults do
  @moduledoc false

  use Snodo.Tool,
    name: "test_elicitation_sep1034_defaults",
    description: "Elicits one field of each primitive type, each with a default (SEP-1034)"

  alias SnodoTest.Conformance.Sessions

  @impl true
  def call(_arguments, context) do
    request =
      Snodo.Elicitation.form("Please review the defaults", %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string", "default" => "John Doe"},
          "age" => %{"type" => "integer", "default" => 30},
          "score" => %{"type" => "number", "default" => 95.5},
          "status" => %{
            "type" => "string",
            "enum" => ["active", "inactive", "pending"],
            "default" => "active"
          },
          "verified" => %{"type" => "boolean", "default" => true}
        }
      })

    Sessions.elicited(context, "defaults", request, "Elicitation completed")
  end
end

defmodule SnodoTest.Conformance.Sessions.Enums do
  @moduledoc false

  use Snodo.Tool,
    name: "test_elicitation_sep1330_enums",
    description: "Elicits the five enum schema variants of SEP-1330"

  alias SnodoTest.Conformance.Sessions

  @impl true
  def call(_arguments, context) do
    request =
      Snodo.Elicitation.form("Please choose", %{
        "type" => "object",
        "properties" => %{
          "untitledSingle" => %{"type" => "string", "enum" => ["option1", "option2", "option3"]},
          "titledSingle" => %{
            "type" => "string",
            "oneOf" => [
              %{"const" => "value1", "title" => "First Option"},
              %{"const" => "value2", "title" => "Second Option"},
              %{"const" => "value3", "title" => "Third Option"}
            ]
          },
          "legacyEnum" => %{
            "type" => "string",
            "enum" => ["opt1", "opt2", "opt3"],
            "enumNames" => ["Option One", "Option Two", "Option Three"]
          },
          "untitledMulti" => %{
            "type" => "array",
            "items" => %{"type" => "string", "enum" => ["option1", "option2", "option3"]}
          },
          "titledMulti" => %{
            "type" => "array",
            "items" => %{
              "anyOf" => [
                %{"const" => "value1", "title" => "First Choice"},
                %{"const" => "value2", "title" => "Second Choice"},
                %{"const" => "value3", "title" => "Third Choice"}
              ]
            }
          }
        }
      })

    Sessions.elicited(context, "enums", request, "Elicitation completed")
  end
end

defmodule SnodoTest.Conformance.Sessions.Watched do
  @moduledoc false

  use Snodo.Resource,
    uri: "test://watched-resource",
    name: "watched_resource",
    description: "A resource clients subscribe to with resources/subscribe",
    mime_type: "text/plain"

  @impl true
  def read(%{"uri" => uri}, _context) do
    {:ok,
     Snodo.Result.resource_read(
       Snodo.Resource.text(uri, "This resource can be watched.", mime_type: "text/plain")
     )}
  end
end
