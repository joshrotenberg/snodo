# Client harness for the official conformance runner's `client` leg.
#
# The runner starts one scenario server per scenario and runs this script with
# the server URL as the last argument. The scenario name arrives in
# MCP_CONFORMANCE_SCENARIO and optional scenario input in
# MCP_CONFORMANCE_CONTEXT. The runner scores the traffic its server records, so
# this script drives Snodo.Client the way an application would and adds no
# protocol behavior of its own:
#
#   1. `server/discover`, then `tools/list`.
#   2. Call the tools the context names in `toolCalls` with their arguments, or
#      else every listed tool with arguments sampled from its input schema.
#      `input_required` results are answered (elicitations are accepted with
#      sampled content) and retried with the returned `requestState`.
#   3. When discovery advertises them, list and read every resource and list
#      and get every prompt.
#
# json-schema-2020-12-preservation instead echoes one tool's input schema, as
# that scenario requires. Scenarios without a flow, including every auth/*
# scenario (Snodo.Client has no OAuth support), exit 1 without a request.

defmodule Snodo.Conformance.ClientHarness do
  @moduledoc false

  alias Snodo.Client

  @max_rounds 4

  def main(argv) do
    url = List.last(argv) || fail("expected the server URL as the last argument")

    scenario =
      System.get_env("MCP_CONFORMANCE_SCENARIO") || fail("MCP_CONFORMANCE_SCENARIO is unset")

    run(scenario, url)
  end

  defp run("auth/" <> _rest = scenario, _url),
    do: fail("#{scenario}: Snodo.Client does not implement OAuth")

  defp run(scenario, url)
       when scenario in [
              "tools_call",
              "request-metadata",
              "sep-2322-client-request-state",
              "http-standard-headers",
              "http-custom-headers",
              "http-invalid-tool-headers",
              "json-schema-ref-no-deref",
              "json-schema-2020-12-preservation"
            ] do
    context =
      case System.get_env("MCP_CONFORMANCE_CONTEXT") do
        nil -> %{}
        json -> JSON.decode!(json)
      end

    {:ok, client} =
      Client.connect({:http, url},
        client_capabilities: %{"elicitation" => %{"form" => %{}}},
        timeout: 10_000
      )

    capabilities =
      case log("server/discover", Client.discover(client)) do
        {:ok, %{"capabilities" => capabilities}} -> capabilities
        _other -> %{}
      end

    tools =
      case log("tools/list", Client.list_tools(client)) do
        {:ok, tools} -> tools
        _other -> fail("#{scenario}: tools/list failed")
      end

    call_tools(client, scenario, tools, context)
    if Map.has_key?(capabilities, "resources"), do: read_resources(client)
    if Map.has_key?(capabilities, "prompts"), do: get_prompts(client)
    Client.close(client)
  end

  defp run(scenario, _url), do: fail("#{scenario}: no harness flow for this scenario")

  defp read_resources(client) do
    with {:ok, resources} <- log("resources/list", Client.list_resources(client)) do
      Enum.each(resources, &log("resources/read", Client.read_resource(client, &1["uri"])))
    end
  end

  defp get_prompts(client) do
    with {:ok, prompts} <- log("prompts/list", Client.list_prompts(client)) do
      Enum.each(prompts, fn prompt ->
        arguments = Map.new(Map.get(prompt, "arguments", []), &{&1["name"], "conformance"})
        log("prompts/get", Client.get_prompt(client, prompt["name"], arguments))
      end)
    end
  end

  defp call_tools(client, "json-schema-2020-12-preservation", tools, _context) do
    focal = Enum.find(tools, &(&1["name"] == "json_schema_2020_12_tool"))
    call_tool(client, "json_schema_echo", %{"schema" => focal["inputSchema"]}, [], 1)
  end

  # Calls pass the listed definition when there is one, so Snodo.Client can
  # send Mcp-Param headers for x-mcp-header arguments.
  defp call_tools(client, _scenario, tools, %{"toolCalls" => calls}) do
    Enum.each(calls, fn call ->
      tool = Enum.find(tools, &(&1["name"] == call["name"])) || call["name"]
      call_tool(client, tool, Map.get(call, "arguments", %{}), [], 1)
    end)
  end

  defp call_tools(client, _scenario, tools, _context) do
    Enum.each(tools, fn tool ->
      call_tool(client, tool, sample(Map.get(tool, "inputSchema", %{})), [], 1)
    end)
  end

  defp call_tool(client, tool, arguments, opts, round) do
    name = if is_map(tool), do: tool["name"], else: tool

    case Client.call_tool(client, tool, arguments, opts) do
      {:input_required, pending} when round < @max_rounds ->
        log("tools/call #{name}", {:input_required, pending})

        retry =
          [input_responses: answer(Map.get(pending, "inputRequests", %{}))] ++
            case Map.fetch(pending, "requestState") do
              {:ok, state} -> [request_state: state]
              :error -> []
            end

        call_tool(client, tool, arguments, retry, round + 1)

      other ->
        log("tools/call #{name}", other)
    end
  end

  # Accept every elicitation with values sampled from its requested schema.
  # Other input request methods are answered with an empty result.
  defp answer(requests) do
    Map.new(requests, fn
      {key, %{"method" => "elicitation/create", "params" => params}} ->
        {key,
         %{"action" => "accept", "content" => sample(Map.get(params, "requestedSchema", %{}))}}

      {key, _request} ->
        {key, %{}}
    end)
  end

  # A minimal value for a JSON Schema: every declared object property, the
  # first enum or const value, and a fixed value per primitive type.
  defp sample(%{"const" => value}), do: value
  defp sample(%{"enum" => [value | _rest]}), do: value
  defp sample(%{"default" => value}), do: value

  defp sample(%{"type" => "object"} = schema),
    do:
      Map.new(Map.get(schema, "properties", %{}), fn {key, property} ->
        {key, sample(property)}
      end)

  defp sample(%{"type" => "array"}), do: []
  defp sample(%{"type" => "string"}), do: "conformance"
  defp sample(%{"type" => type}) when type in ["number", "integer"], do: 1
  defp sample(%{"type" => "boolean"}), do: true
  defp sample(%{"type" => [type | _rest]} = schema), do: sample(%{schema | "type" => type})

  defp sample(%{"properties" => _properties} = schema),
    do: sample(Map.put(schema, "type", "object"))

  defp sample(_schema), do: nil

  defp log(label, result) do
    IO.puts(:stderr, "#{label}: #{inspect(result, limit: 20)}")
    result
  end

  defp fail(message) do
    IO.puts(:stderr, message)
    System.halt(1)
  end
end

Snodo.Conformance.ClientHarness.main(System.argv())
