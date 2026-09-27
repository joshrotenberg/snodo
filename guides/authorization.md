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

The Tasks extension runs the `:invocation` check, and argument validation,
when it accepts a task-augmented `tools/call`, before it stores anything. Work
that a durable executor later runs has already passed the check. Inside the
task worker, `context.request_method` is still `"tools/call"`.

## What it does not do

- It does not authenticate. `context.auth` is whatever the transport or
  application put there: a Plug pipeline, or `auth:` on `Snodo.Client.direct/2`
  in tests.
- It defines no roles, scopes, or refusal codes. The application chooses the
  code (JSON-RPC reserves -32000 to -32099 for implementation-defined errors).
- It does not log. The callback is the place to record refusals.
- It does not filter list-changed notifications, which carry no component
  data. Subscription sources receive the same context for anything else.

A `subscriptions/listen` request's `resourceSubscriptions` pass through the
`:invocation` check as reads: a resource the caller may not read is left out of
the accepted filter, so its updates are never delivered. A URI that no resource
matches is kept, since there is no component to decide on.

With a policy, the tools, prompts, and resources caches must use scope
`"private"`: results differ per principal, and a public hint would let a shared
cache hand one principal's result to another. `Snodo.Server.Runtime.new/1`
raises otherwise.

A policy that raises or returns anything else is a fault: the operation fails
rather than silently emptying a catalog. The callback runs once per listed
component, so keep it cheap.

## Example

`examples/23_authorization.exs`.
