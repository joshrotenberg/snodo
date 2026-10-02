# GenServer tool experiment, 2026-10-02

Issue #229 asked whether GenServer operations could be exposed through MCP
without a handwritten `Snodo.Tool` module for each operation. The Counter
example has three manual adapters and three generated adapters for a read call,
a state-changing call, and a cast. The generated modules use the normal server
registration path and advertise the same input schemas as the manual modules.
The call results and cast send acknowledgements match through
`Snodo.Client.direct/1`.

## Declarations that remain necessary

A GenServer callback accepts application-defined Elixir terms. The adapter
therefore requires an explicit MCP name, fixed registered target, input JSON
Schema, and message builder. Calls also require a reply encoder returning a JSON
object. The declaration may provide a description, output schema, and timeout.
The default call timeout is 5,000 ms. Input validation runs before message
construction. Assertions outside the bundled Basic validator's subset fail
compilation rather than being advertised without enforcement. Failed calls and
invalid JSON replies become tool errors. Casts check for an absent target
before sending, then report only that `GenServer.cast/2` accepted the message.
The target can stop between those steps, so an acknowledgement does not prove
receipt or processing.

For the example Counter, `__info__(:functions)` reported `start_link/1`,
`init/1`, `handle_call/3`, `handle_cast/2`, and GenServer support functions. It
did not enumerate `:get`, `{:add, by}`, or `:reset`. `Code.fetch_docs/1`
returned `{:error, :module_not_found}` for this script-defined module, and
`Code.Typespec.fetch_specs/1` returned `:error`. Even when an application
supplies docs and typespecs, they cannot derive the application's chosen JSON
input schema, authorization policy, or reply encoding. No operation is exposed
by inspecting the module.

## Generic tool comparison

The example's `counter_operation` tool has an `operation` enum restricted to
the same three generated declarations and dispatches to those modules. Its
calls return the same results. Its `tools/list` entry has one broad
`arguments` object, while the named tools each advertise their required fields
and output schema directly. A client must add the operation selector on every
generic call. The generic tool remains an example prototype; named generated
tools provide a clearer catalog and are the supported declaration result. Its
direct dispatch to a generated module bypasses any router authorization rule
on that named tool. A policy that permits `counter_operation` but denies
`counter_add` would not stop the generic tool from adding. An application
using a generic tool needs its own per-operation authorization before dispatch.

The adapter intentionally does not infer operations from callback clauses,
public functions, docs, or typespecs. It does not expose arbitrary process
names, atoms, terms, `send/2`, `handle_info/2`, or Supervisor operations.
