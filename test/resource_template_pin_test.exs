defmodule Snodo.ResourceTemplatePinTest do
  @moduledoc """
  Pins what the segment-only matcher matched before RFC 6570 operators were
  supported (#151). Every template here compiled then, and must keep matching
  exactly the URIs listed for it, with the same bindings, and nothing else in
  the corpus.
  """

  use ExUnit.Case, async: true

  alias Snodo.Resource.Template

  @uris [
    "hex://jason/info",
    "hex://jason",
    "hex://jason/",
    "hex://jason/info/",
    "hex://jason//info",
    "hex:///info",
    "hex://jason/readme",
    "HEX://Jason/Info",
    "hex://jason/Info",
    "hex://Jason/info",
    "hex://jason/info?full=1",
    "hex://jason/info?",
    "hex://jason/info#top",
    "hex://jason/info#",
    "hex://jason:8080/info",
    "hex://jason:/info",
    "hex://user@jason/info",
    "hex://jason/jason",
    "hex://jason/%6Aason",
    "hex://jason/ecto",
    "hex://packages/jason/jason",
    "hex://packages/jason/ecto",
    "hex://packages/hello%20world/ecto",
    "hex://packages/hello%20World/ecto",
    "hex://jason/a%2Fb",
    "hex://jason/a%2fb",
    "hex://jason/a/b",
    "hex://jason/releases/1.0.0",
    "hex://jason/releases/",
    "hex://jason/releases",
    "hex://bad%GG/info",
    "hex://caf%C3%A9/info",
    "hex://%FF/info",
    "hex://a%2Fb/info",
    "hex://a+b/info",
    "hex://{name}/info",
    "hex://jason/info/extra",
    "npm://jason/info",
    "toolbox://web/frameworks",
    "toolbox://web/web%20frameworks",
    "toolbox://web/a%252Fb",
    "toolbox://web/",
    "toolbox://groups",
    "toolbox://groups/web",
    "toolbox://web//frameworks",
    "toolbox://web/%C3%28",
    "https://example.com/info",
    "https://example.com:443/info",
    "https://example.com:8080/info",
    "http://example.com/info",
    "test://archives/2024/report",
    "test://archives/2024",
    "repo://joshrotenberg/snodo",
    "repo://joshrotenberg/snodo?ref=main",
    "notes://42",
    "notes://42/",
    "notes://4%202",
    "files://root/x/y/z",
    "files://root/x/y",
    "hex://jason/..",
    "hex://../info",
    "hex://./info",
    "not a uri",
    "hex:jason/info",
    "hex:/jason/info",
    "",
    "hex://jason/info%",
    "hex://ja son/info"
  ]

  # {template, variables/1, URIs in @uris that match => bindings}
  @pinned [
    {"hex://{name}/info", ["name"],
     %{
       "hex://../info" => %{"name" => ".."},
       "hex://./info" => %{"name" => "."},
       "hex://Jason/info" => %{"name" => "Jason"},
       "hex://a%2Fb/info" => %{"name" => "a/b"},
       "hex://a+b/info" => %{"name" => "a+b"},
       "hex://caf%C3%A9/info" => %{"name" => "café"},
       "hex://jason/info" => %{"name" => "jason"}
     }},
    {"hex://{name}", ["name"], %{"hex://jason" => %{"name" => "jason"}}},
    {"HeX://{name}/Info", ["name"],
     %{"HEX://Jason/Info" => %{"name" => "Jason"}, "hex://jason/Info" => %{"name" => "jason"}}},
    {"toolbox://{group}/{category}", ["group", "category"],
     %{
       "toolbox://groups/web" => %{"category" => "web", "group" => "groups"},
       "toolbox://web/a%252Fb" => %{"category" => "a%2Fb", "group" => "web"},
       "toolbox://web/frameworks" => %{"category" => "frameworks", "group" => "web"},
       "toolbox://web/web%20frameworks" => %{"category" => "web frameworks", "group" => "web"}
     }},
    {"toolbox://groups/{category}", ["category"],
     %{"toolbox://groups/web" => %{"category" => "web"}}},
    {"hex://{name}/releases/{version}", ["name", "version"],
     %{"hex://jason/releases/1.0.0" => %{"name" => "jason", "version" => "1.0.0"}}},
    {"hex://{name}/{name}", ["name", "name"],
     %{"hex://jason/%6Aason" => %{"name" => "jason"}, "hex://jason/jason" => %{"name" => "jason"}}},
    {"hex://packages/{name}/{name}", ["name", "name"],
     %{"hex://packages/jason/jason" => %{"name" => "jason"}}},
    {"hex://packages/hello%20world/{name}", ["name"],
     %{"hex://packages/hello%20world/ecto" => %{"name" => "ecto"}}},
    {"hex://{name}/a%2Fb", ["name"], %{"hex://jason/a%2Fb" => %{"name" => "jason"}}},
    {"https://{host}/info", ["host"],
     %{"https://example.com/info" => %{"host" => "example.com"}}},
    {"test://archives/{year}/{name}", ["year", "name"],
     %{"test://archives/2024/report" => %{"name" => "report", "year" => "2024"}}},
    {"repo://{owner}/{name}", ["owner", "name"],
     %{"repo://joshrotenberg/snodo" => %{"name" => "snodo", "owner" => "joshrotenberg"}}},
    {"notes://{id}", ["id"],
     %{"notes://4%202" => %{"id" => "4 2"}, "notes://42" => %{"id" => "42"}}},
    {"files://root/{a.b}/{c-d}/{e_f}", ["a.b", "c-d", "e_f"],
     %{"files://root/x/y/z" => %{"a.b" => "x", "c-d" => "y", "e_f" => "z"}}}
  ]

  test "templates that compiled before #151 match the same URIs with the same bindings" do
    for {template, variables, matches} <- @pinned do
      assert {:ok, compiled} = Template.compile(template), template
      assert Template.variables(compiled) == variables, template

      for uri <- @uris do
        expected =
          case Map.fetch(matches, uri) do
            {:ok, bound} -> {:ok, bound}
            :error -> :error
          end

        assert Template.match(compiled, uri) == expected,
               "#{template} against #{inspect(uri)}"
      end
    end
  end
end
