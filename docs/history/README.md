# Project decision records

This directory holds dated decision records that explain the choices behind
the code, the alternatives considered, and the consequences. Write one
`YYYY-MM-DD-topic.md` file per decision. Decision records stay as written
after merge. Add a new dated record when a decision is superseded.

The [guides](../../guides) describe the current library.

- [GenServer tool experiment](2026-10-02-genserver-tools.md) explains why
  generated tools require explicit operation declarations and expose each
  operation by name.
- [JSON-RPC error HTTP status](2026-11-19-jsonrpc-error-http-status.md)
  explains why execution-phase -32602 and -32603 errors return HTTP 200 on
  the 2026-07-28 binding.
- [Events extension](2026-11-19-events-extension.md) records the decision to
  defer SEP-3415 and sketches an Events sibling package.
