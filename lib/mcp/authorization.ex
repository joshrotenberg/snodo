defmodule MCP.Authorization do
  @moduledoc """
  Optional application-owned authorization at the component boundary.

  The application decides whether a request context may discover or invoke a
  registered component. `mcp_ex` applies that decision inside the router, below
  every transport and protocol dialect, and before argument validation or any
  application callback. The library supplies no identity, role, token, or
  policy vocabulary and never interprets the returned error.

  Configure a runtime with `authorization: MyApp.Policy` or
  `authorization: {MyApp.Policy, options}`; the second element is passed back
  unchanged on every call. An unconfigured runtime performs no extra work.

      defmodule MyApp.Policy do
        @behaviour MCP.Authorization

        alias MCP.Authorization.Component

        @impl true
        def authorize(phase, %Component{} = component, context, _options) do
          if allowed?(context.auth, component) do
            :ok
          else
            if phase == :invocation, do: MyApp.Audit.refused(context.auth, component)
            {:error, MCP.Error.authorization(-32_003, "Not authorized")}
          end
        end
      end

  ## Phases

  `:discovery` covers `tools/list`, `prompts/list`, `resources/list`, and
  `resources/templates/list`. A refusal removes the component from that
  response, so the client never learns the name exists.

  `:invocation` covers `tools/call`, `prompts/get`, `resources/read`, and
  `completion/complete`. A refusal is returned to the client as the
  application's own `MCP.Error`, which keeps a boundary violation distinct from
  an unknown name and gives the policy the one place to record an audit event.
  `MCP.Context.request_method` names the exact operation being refused.

  Only the enforcement seam lives here. Server capability advertisement stays
  catalog-wide, because it describes the server rather than one request.
  Application-owned subscription sources and negotiated extension routes
  receive the same `MCP.Context` and own their policy, because neither
  dispatches through the router catalog.

  A policy that raises, exits, throws, or returns something else is a fault
  rather than a decision: the operation fails with an internal error in both
  phases instead of silently emptying a catalog.
  """

  alias MCP.Authorization.Component
  alias MCP.Context
  alias MCP.Error

  @type phase :: :discovery | :invocation
  @type config :: nil | {module(), term()}
  @type decision :: :ok | {:refused, Error.t()} | {:fault, Error.t()}

  @doc """
  Decides whether `context` may discover or invoke `component`.

  Return `:ok` to allow, or `{:error, %MCP.Error{}}` to refuse. The error is
  returned verbatim during `:invocation` and only hides the component during
  `:discovery`.
  """
  @callback authorize(phase(), Component.t(), Context.t(), term()) ::
              :ok | {:error, Error.t()}

  @doc false
  @spec normalize!(nil | module() | {module(), term()}) :: config()
  def normalize!(nil), do: nil
  def normalize!(module) when is_atom(module), do: normalize!({module, []})

  def normalize!({module, options}) when is_atom(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        unless function_exported?(module, :authorize, 4) do
          raise ArgumentError, "authorization policy must export authorize/4"
        end

        {module, options}

      _not_loaded ->
        raise ArgumentError, "authorization policy #{inspect(module)} could not be loaded"
    end
  end

  def normalize!(_invalid) do
    raise ArgumentError, "authorization must be a module or a {module, options} tuple"
  end

  @doc false
  @spec decide(config(), phase(), Component.t(), Context.t()) :: decision()
  def decide(nil, _phase, %Component{}, %Context{}), do: :ok

  def decide({module, options}, phase, %Component{} = component, %Context{} = context)
      when phase in [:discovery, :invocation] do
    case module.authorize(phase, component, context, options) do
      :ok ->
        :ok

      {:error, %Error{code: code, message: message} = error}
      when is_integer(code) and is_binary(message) ->
        {:refused, error}

      other ->
        {:fault, Error.internal("Authorization policy returned an invalid decision", other)}
    end
  rescue
    exception ->
      {:fault,
       Error.internal("Authorization policy raised an exception", {exception, __STACKTRACE__})}
  catch
    kind, reason ->
      {:fault,
       Error.internal(
         "Authorization policy terminated unexpectedly",
         {kind, reason, __STACKTRACE__}
       )}
  end
end
