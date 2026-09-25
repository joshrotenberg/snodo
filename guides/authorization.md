# Authorization

Authorization is an optional seam, not a role system. The application supplies a
policy module; `snodo` calls it and enforces the decision.

```elixir
defmodule MyApp.Policy do
  @behaviour Snodo.Authorization

  @impl true
  def authorize(_phase, %Snodo.Authorization.Component{kind: :tool, name: "admin_reset"}, context, _options) do
    if admin?(context.auth), do: :ok, else: {:error, Snodo.Error.authorization(-32_003, "Not permitted")}
  end

  def authorize(_phase, _component, _context, _options), do: :ok

  defp admin?(%{"role" => "admin"}), do: true
  defp admin?(_auth), do: false
end

defmodule MyApp.Server do
  use Snodo.Server,
    name: "my-server",
    version: "1.0.0",
    authorization: {MyApp.Policy, []}
end
```

## Where it applies

The seam sits inside the router, below every transport and dialect, so direct
dispatch, stdio, the native HTTP listener, and Plug share one decision.

| Phase | Operations | Effect of a refusal |
|---|---|---|
| `:discovery` | `tools/list`, `prompts/list`, `resources/list`, `resources/templates/list` | the component is left out of the list |
| `:invocation` | `tools/call`, `prompts/get`, `resources/read`, `completion/complete` | the request fails with the policy's own `Snodo.Error`, before argument validation and before any application callback |

Filtering happens before paging, so a cursor belongs to the catalog that
context can see and expires if replayed against a different one.

## What it does not do

- It does not authenticate. `context.auth` is whatever the transport or
  application put there: a Plug pipeline, or `auth:` on `Snodo.Client.direct/2`
  in tests.
- It defines no roles, scopes, or refusal codes. The application chooses the
  code (JSON-RPC reserves -32000 to -32099 for implementation-defined errors).
- It does not log. The callback is the place to record refusals.
- It does not filter subscription streams, which receive the same context and
  enforce their own policy.

A policy that raises or returns anything else is a fault: the operation fails
rather than silently emptying a catalog. The callback runs once per listed
component, so keep it cheap.

## Example

`examples/23_authorization.exs`.
