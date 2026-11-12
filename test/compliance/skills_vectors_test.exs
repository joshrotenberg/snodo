defmodule Snodo.Compliance.SkillsVectorsTest do
  # Literal io.modelcontextprotocol/skills messages (SEP-2640) against the
  # server in test/support/skills.ex, through direct and stdio admission.
  # These are extension vectors and carry no core :mcp_contract tag.
  use ExUnit.Case, async: true

  alias Snodo.Server
  alias Snodo.Transport.Context, as: TransportContext
  alias Snodo.Transport.Stdio
  alias SnodoTest.SkillsServer

  @declared %{
    "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
    "io.modelcontextprotocol/clientCapabilities" => %{
      "extensions" => %{"io.modelcontextprotocol/skills" => %{}}
    }
  }

  @undeclared %{
    "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
    "io.modelcontextprotocol/clientCapabilities" => %{}
  }

  test "server/discover declares the extension inline, next to resources" do
    response =
      both(%{
        "jsonrpc" => "2.0",
        "id" => "discover",
        "method" => "server/discover",
        "params" => %{"_meta" => @undeclared}
      })

    assert %{
             "result" => %{
               "capabilities" => %{
                 "resources" => %{},
                 "extensions" => %{
                   "io.modelcontextprotocol/skills" => %{"directoryRead" => true}
                 }
               }
             }
           } = response
  end

  test "skills/list returns whole entries with digests, sizes, and a cursor" do
    response =
      both(%{
        "jsonrpc" => "2.0",
        "id" => "list-1",
        "method" => "skills/list",
        "params" => %{"_meta" => @declared}
      })

    assert %{
             "jsonrpc" => "2.0",
             "id" => "list-1",
             "result" => %{
               "resultType" => "complete",
               "ttlMs" => 0,
               "cacheScope" => "private",
               "nextCursor" => cursor,
               "skills" => [
                 %{
                   "uri" => "skill://acme/release-notes/SKILL.md",
                   "frontmatter" => %{
                     "name" => "release-notes",
                     "description" => "Write release notes from merged changes",
                     "allowed-tools" => ["Read", "Grep"]
                   },
                   "resources" => [
                     %{
                       "uri" => "skill://acme/release-notes/SKILL.md",
                       "digest" =>
                         "sha256:7dc1408a32966636273c2783a8041ebf0b1f08bbd0ed08ebbe6f386efb02e006",
                       "size" => 135
                     }
                   ]
                 },
                 %{
                   "uri" => "skill://inline-tool/SKILL.md",
                   "frontmatter" => %{
                     "name" => "inline-tool",
                     "description" => "Supplied by the application"
                   },
                   "resources" => [
                     %{
                       "uri" => "skill://inline-tool/SKILL.md",
                       "digest" =>
                         "sha256:63b33d645269f7519721269b6d8ee65fbdb801c2eddd53c349ebb79bbabcade9",
                       "size" => 72
                     },
                     %{
                       "uri" => "skill://inline-tool/data/blob.bin",
                       "digest" =>
                         "sha256:e92ad0d01485ac7095ffc21874b70b74f9667cf2c937b8ab2527a96d847fb21e",
                       "size" => 5
                     }
                   ]
                 }
               ]
             }
           } = response

    assert map_size(response["result"]) == 5

    second =
      both(%{
        "jsonrpc" => "2.0",
        "id" => "list-2",
        "method" => "skills/list",
        "params" => %{"cursor" => cursor, "_meta" => @declared}
      })

    assert %{"result" => %{"skills" => [%{"uri" => "skill://pdf-processing/SKILL.md"} = pdf]}} =
             second

    refute Map.has_key?(second["result"], "nextCursor")

    assert %{
             "uri" => "skill://pdf-processing/SKILL.md",
             "digest" =>
               "sha256:4b1ba06b4049e544e3e3fbd9b84e3233aa8e347ce31ed8c6b9c81b675b94e210",
             "size" => 205
           } in pdf["resources"]
  end

  test "skills/get returns one entry without a cursor" do
    response =
      both(%{
        "jsonrpc" => "2.0",
        "id" => "get",
        "method" => "skills/get",
        "params" => %{"uri" => "skill://acme/release-notes/SKILL.md", "_meta" => @declared}
      })

    assert response == %{
             "jsonrpc" => "2.0",
             "id" => "get",
             "result" => %{
               "resultType" => "complete",
               "ttlMs" => 0,
               "cacheScope" => "private",
               "skill" => %{
                 "uri" => "skill://acme/release-notes/SKILL.md",
                 "frontmatter" => %{
                   "name" => "release-notes",
                   "description" => "Write release notes from merged changes",
                   "allowed-tools" => ["Read", "Grep"]
                 },
                 "resources" => [
                   %{
                     "uri" => "skill://acme/release-notes/SKILL.md",
                     "digest" =>
                       "sha256:7dc1408a32966636273c2783a8041ebf0b1f08bbd0ed08ebbe6f386efb02e006",
                     "size" => 135
                   }
                 ]
               }
             }
           }
  end

  test "resources/directory/read lists children with inode/directory subdirectories" do
    response =
      both(%{
        "jsonrpc" => "2.0",
        "id" => "dir",
        "method" => "resources/directory/read",
        "params" => %{"uri" => "skill://inline-tool", "_meta" => @declared}
      })

    assert response == %{
             "jsonrpc" => "2.0",
             "id" => "dir",
             "result" => %{
               "resultType" => "complete",
               "ttlMs" => 0,
               "cacheScope" => "private",
               "resources" => [
                 %{
                   "uri" => "skill://inline-tool/SKILL.md",
                   "name" => "SKILL.md",
                   "mimeType" => "text/markdown",
                   "size" => 72
                 },
                 %{
                   "uri" => "skill://inline-tool/data",
                   "name" => "data",
                   "mimeType" => "inode/directory"
                 }
               ]
             }
           }
  end

  test "errors keep their codes and IDs" do
    cases = [
      {"skills/get", %{"uri" => "skill://mcp-conformance-nonexistent-skill-9f3a2b/SKILL.md"},
       @declared,
       %{
         "code" => -32_602,
         "message" => "Unknown skill",
         "data" => %{"uri" => "skill://mcp-conformance-nonexistent-skill-9f3a2b/SKILL.md"}
       }},
      {"resources/directory/read", %{"uri" => "skill://inline-tool/SKILL.md"}, @declared,
       %{
         "code" => -32_602,
         "message" => "Not a skill directory",
         "data" => %{"uri" => "skill://inline-tool/SKILL.md"}
       }},
      {"skills/list", %{"cursor" => "skills1.bm90LWEtY3Vyc29y"}, @declared,
       %{"code" => -32_602, "message" => "Invalid pagination cursor"}},
      {"skills/list", %{}, @undeclared,
       %{
         "code" => -32_021,
         "message" => "Missing required client capability",
         "data" => %{
           "requiredCapabilities" => %{
             "extensions" => %{"io.modelcontextprotocol/skills" => %{}}
           }
         }
       }}
    ]

    for {{method, params, meta, error}, index} <- Enum.with_index(cases) do
      id = "error-#{index}"

      raw = %{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => method,
        "params" => Map.put(params, "_meta", meta)
      }

      assert both(raw) == %{"jsonrpc" => "2.0", "id" => id, "error" => error}, method
    end
  end

  # Dispatches through direct and stdio admission, which must agree.
  defp both(raw) do
    runtime = SkillsServer.runtime()
    {:ok, direct} = Server.dispatch(runtime, raw, %TransportContext{transport: :direct})

    {:ok, io} = StringIO.open(JSON.encode!(raw) <> "\n")
    assert :ok = Stdio.serve(runtime, input: io, output: io)
    {_input, output} = StringIO.contents(io)
    assert [line] = String.split(output, "\n", trim: true)
    assert JSON.decode!(line) == direct
    direct
  end
end
