"""Acceptance checks using the unmodified official Python MCP client."""

import asyncio
import json
import os
from contextlib import asynccontextmanager
from pathlib import Path

from mcp import Client, StdioServerParameters, types
from mcp.client.stdio import stdio_client


ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
ELIXIR = os.environ.get("SNODO_ELIXIR", "elixir")
ENV = {**os.environ, "ERL_FLAGS": os.environ.get("ERL_FLAGS", "+S 4:4")}
VERSIONS = ("2026-07-28", "2025-11-25", "2025-06-18")
TRANSPORTS = ("stdio", "http")


@asynccontextmanager
async def server(fixture: Path, transport: str, version: str | None = None):
    args = [str(fixture), f"--{transport}"]
    if version is not None:
        args.append(version)

    if transport == "stdio":
        yield stdio_client(StdioServerParameters(command=ELIXIR, args=args, cwd=ROOT, env=ENV))
        return

    process = await asyncio.create_subprocess_exec(
        ELIXIR,
        *args,
        cwd=ROOT,
        env=ENV,
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        line = await asyncio.wait_for(process.stdout.readline(), 15)
        if not line:
            raise AssertionError(f"HTTP fixture exited before readiness: {await process.stderr.read()}")
        url = json.loads(line)["url"]
        assert url.startswith("http://127.0.0.1:")
        yield url
    finally:
        process.stdin.close()
        try:
            await asyncio.wait_for(process.wait(), 5)
        except TimeoutError:
            process.kill()
            await process.wait()
            raise AssertionError("HTTP fixture failed to stop on stdin EOF")
        diagnostics = (await process.stderr.read()).decode()
        assert process.returncode == 0, diagnostics


def text_result(result):
    assert not result.is_error, result
    assert result.content[0].type == "text", result
    return result.content[0].text


async def baseline(transport: str, version: str):
    async with server(HERE / "fixture.exs", transport, version) as target:
        mode = "auto" if version == "2026-07-28" else "legacy"
        async with Client(target, mode=mode) as client:
            assert client.protocol_version == version
            assert client.server_info.name == "python-interop"
            tools = await client.list_tools()
            assert [item.name for item in tools.tools] == ["echo"]
            assert tools.tools[0].input_schema["type"] == "object"
            assert text_result(await client.call_tool("echo", {"text": "python-ok"})) == "python-ok"

            resources = await client.list_resources()
            assert [item.uri for item in resources.resources] == ["interop://greeting"]
            read = await client.read_resource("interop://greeting")
            assert read.contents[0].text == "hello from snodo"

            prompts = await client.list_prompts()
            assert [item.name for item in prompts.prompts] == ["greet"]
            prompt = await client.get_prompt("greet", {"name": "Python"})
            assert prompt.messages[0].content.text == "Hello, Python"

            return {"transport": transport, "version": version, "operations": 7}


async def answer_elicitation(_context, params):
    if params.mode == "url":
        assert params.url == "https://example.invalid/preferences"
        return types.ElicitResult(action="accept")
    field = params.requested_schema["required"][0]
    values = {"color": "blue", "style": "compact", "label": "fresh"}
    return types.ElicitResult(action="accept", content={field: values[field]})


async def mrtr(transport: str):
    async with server(HERE.parent / "official_client/mrtr_fixture.exs", transport) as target:
        async with Client(target, mode="auto", elicitation_callback=answer_elicitation) as client:
            assert client.protocol_version == "2026-07-28"
            result = await client.call_tool("preference_preview", {"subject": "python"})
            expected = {"color": "blue", "style": "compact", "status": "preview"}
            assert json.loads(text_result(result)) == expected

            resource = await client.read_resource("preview://preferences")
            assert json.loads(resource.contents[0].text) == expected
            prompt = await client.get_prompt("preference_prompt")
            assert json.loads(prompt.messages[0].content.text) == expected

            reset = await client.call_tool("reset_preview", {})
            assert json.loads(text_result(reset)) == {"status": "accept", "stateDiscarded": True}
            url = await client.call_tool("url_preview", {})
            assert json.loads(text_result(url)) == {"consent": "accept", "externalStatus": "pending"}
            return {"transport": transport, "mrtr": "tool/resource/prompt, state and URL"}


async def progress(transport: str):
    async with server(HERE.parent / "official_client/progress_fixture.exs", transport) as target:
        async with Client(target, mode="auto", elicitation_callback=answer_elicitation) as client:
            assert client.protocol_version == "2026-07-28"
            observations = []
            acknowledgements = []

            async def callback(value, total, message):
                observations.append((value, total, message))
                acknowledgements.append(
                    asyncio.create_task(
                        client.call_tool(
                            "progress_ack", {"operation": "python-progress", "value": int(value)}
                        )
                    )
                )

            result = await client.call_tool(
                "progress_preview",
                {"mode": "mrtr", "operation": "python-progress"},
                progress_callback=callback,
            )
            assert text_result(result) == "fresh"
            assert all(
                text_result(acknowledged) == "acknowledged"
                for acknowledged in await asyncio.gather(*acknowledgements)
            )
            assert observations == [
                (value, 100, f"Stage {value}") for value in (0, 50, 100, 0, 50, 100)
            ]
            return {"transport": transport, "progress_callbacks": len(observations)}


async def main():
    baseline_checks = [
        await baseline(transport, version)
        for transport in TRANSPORTS
        for version in VERSIONS
    ]
    mrtr_checks = [await mrtr(transport) for transport in TRANSPORTS]
    progress_checks = [await progress(transport) for transport in TRANSPORTS]
    print(json.dumps({"baseline": baseline_checks, "mrtr": mrtr_checks, "progress": progress_checks}))


if __name__ == "__main__":
    asyncio.run(main())
