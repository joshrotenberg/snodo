# Official Python client acceptance

These checks use the unmodified official `mcp` Python SDK 2.0.0 against Snodo's
public server APIs. `pyproject.toml` pins the SDK and `uv.lock` pins its
dependencies. Python 3.13 and uv 0.12.21 are required.

From the repository root:

```sh
MIX_ENV=dev mix compile --warnings-as-errors
cd interop/official_python
uv sync --frozen
uv run --frozen python check.py
```

The baseline checks exercise the Python client over stdio and native Streamable
HTTP. Each transport runs against 2026-07-28, 2025-11-25, and 2025-06-18,
checking version negotiation or discovery, tool listing and calls, resource
listing and reads, and prompt listing and retrieval. A separate modern-protocol
check covers automatic MRTR retries with form and URL elicitation for tools,
resources, and prompts. The progress check verifies callbacks across an MRTR
retry on each transport.

The HTTP fixtures bind to loopback on an ephemeral port and stop on stdin EOF.
The checks do not visit elicitation URLs or call public services. A passing
result prints a JSON summary. CI runs the same command and uploads its output
even on failure. The reverse direction, Snodo.Client against official Python
servers, remains future work as the client gains more feature coverage.

`SNODO_ELIXIR` selects the Elixir executable. `SNODO_EBIN` overrides the default
`_build/dev/lib/snodo/ebin` directory.
