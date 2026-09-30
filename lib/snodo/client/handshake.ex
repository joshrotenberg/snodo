defmodule Snodo.Client.Handshake do
  @moduledoc false
  # Version negotiation for `Snodo.Client.connect/2` and `direct/2`: the
  # dialects the `:protocol` option allows, the `server/discover` probe, and
  # the initialize-era handshake. The client speaks every bundled dialect;
  # `Snodo.Protocol.builtin_dialects/0` is the one list.

  alias Snodo.Client
  alias Snodo.Client.Session
  alias Snodo.Client.Transport
  alias Snodo.Error
  alias Snodo.Protocol.Registry

  @doc false
  # The dialects the `:protocol` option allows, in the client's preference
  # order (newest first), whatever order a list gives them in.
  @spec dialects(term()) :: {:ok, [module()]} | {:error, Error.t()}
  def dialects(nil), do: {:ok, Snodo.Protocol.builtin_dialects()}
  def dialects(version) when is_binary(version), do: dialects([version])

  def dialects(versions) when is_list(versions) and versions != [] do
    unless Enum.all?(versions, &is_binary/1), do: invalid_option!(versions)
    supported = Snodo.Protocol.builtin_dialects()

    case Enum.reject(versions, fn version -> Enum.any?(supported, &(&1.version() == version)) end) do
      [] ->
        {:ok, Enum.filter(supported, &(&1.version() in versions))}

      [unsupported | _others] ->
        {:error,
         Error.invalid_params("Snodo.Client does not support protocol #{unsupported}", %{
           "requested" => unsupported,
           "supported" => versions(supported)
         })}
    end
  end

  def dialects(other), do: invalid_option!(other)

  @spec invalid_option!(term()) :: no_return()
  defp invalid_option!(value) do
    raise ArgumentError,
          ":protocol must be a version string or a non-empty list of version strings, " <>
            "got: #{inspect(value)}"
  end

  @doc false
  # A direct client knows which versions the runtime enables, so the highest
  # allowed one among them is chosen without a probe.
  @spec enabled(Registry.t(), [module()]) :: {:ok, module()} | {:error, Error.t()}
  def enabled(%Registry{} = registry, dialects) do
    enabled = Registry.versions(registry)

    case Enum.find(dialects, &(&1.version() in enabled)) do
      nil ->
        {:error,
         Error.invalid_params(
           "The runtime enables none of the protocol versions the client allows",
           %{"requested" => versions(dialects), "enabled" => enabled}
         )}

      dialect ->
        {:ok, dialect}
    end
  end

  @doc false
  # Negotiates the version on a freshly connected transport and returns the
  # client that speaks it. `reopen` closes and reconnects the transport; it
  # is used before falling back to `initialize` after a probe, because the
  # probe may already have been processed under legacy semantics, which on
  # stdio means a new server process.
  @spec run(
          Client.t(),
          [module()],
          (-> {:ok, Transport.state()} | {:error, Error.t()}),
          keyword()
        ) ::
          {:ok, Client.t()} | {:error, Error.t()}
  def run(%Client{} = client, dialects, reopen, opts) do
    {stateless, session} = Enum.split_with(dialects, &(&1.era() == :stateless))

    cond do
      session == [] -> {:ok, speak(client, hd(stateless))}
      stateless == [] -> initialize(client, session)
      true -> probe(client, dialects, session, reopen, opts)
    end
  end

  # `server/discover` on the newest stateless dialect. A result with
  # `supportedVersions` is a modern server's answer and settles the version.
  # Anything else, whatever the error code or the shape, means the server does
  # not speak a stateless version.
  defp probe(client, dialects, session, reopen, opts) do
    probe_client = speak(client, hd(dialects))
    timeout = Keyword.fetch!(opts, :probe_timeout)

    case Client.request(probe_client, "server/discover", %{},
           timeout: timeout,
           answer_input: false
         ) do
      {:ok, %{"supportedVersions" => versions}} when is_list(versions) ->
        settle(client, dialects, session, versions)

      _non_modern ->
        with {:ok, client} <- reopen_transport(client, reopen), do: initialize(client, session)
    end
  end

  # The highest allowed version a modern server lists. An initialize-era one
  # is initialized on the same connection: a stateless server kept nothing
  # from the probe.
  defp settle(client, dialects, session, versions) do
    case Enum.find(dialects, &(&1.version() in versions)) do
      nil -> close_with(client, no_common_version(dialects, versions))
      dialect -> adopt(client, dialect, session)
    end
  end

  defp adopt(client, dialect, session) do
    if dialect.era() == :stateless,
      do: {:ok, speak(client, dialect)},
      else: initialize(client, Enum.drop_while(session, &(&1 != dialect)))
  end

  defp reopen_transport(%Client{transport: {module, state}} = client, reopen) do
    :ok = module.close(state)
    with {:ok, state} <- reopen.(), do: {:ok, %{client | transport: {module, state}}}
  end

  # `initialize` proposes the highest allowed initialize-era version. The
  # server answers with that version or another it prefers; one the client
  # does not allow ends the connection, as the specification asks.
  defp initialize(%Client{transport: {module, _state}} = client, [proposed | _others] = allowed) do
    client = speak(client, proposed)

    if function_exported?(module, :notify, 3) do
      ref = make_ref()
      owner = self()

      params = %{
        "protocolVersion" => proposed.version(),
        "capabilities" => client.client_capabilities,
        "clientInfo" => client.client_info
      }

      case Client.request(client, "initialize", params,
             answer_input: false,
             on_response_headers: &send(owner, {ref, &1})
           ) do
        {:ok, %{"protocolVersion" => version} = result} when is_binary(version) ->
          headers = collect_headers(ref)
          open_session(client, allowed, version, result, headers)

        {:ok, result} ->
          close_with(
            client,
            Transport.connection_error("The initialize result has no protocolVersion", result)
          )

        {:input_required, result} ->
          close_with(
            client,
            Transport.connection_error(
              "The server answered initialize with an input request",
              result
            )
          )

        {:error, %Error{} = error} ->
          close_with(client, error)
      end
    else
      close_with(
        client,
        Error.invalid_params(
          "#{inspect(module)} cannot open an initialize-era connection: it has no notify/3",
          %{"requested" => versions(allowed)}
        )
      )
    end
  end

  defp open_session(client, allowed, version, result, headers) do
    case Enum.find(allowed, &(&1.version() == version)) do
      nil ->
        close_with(
          client,
          Error.invalid_params(
            "The server negotiated protocol #{version}, which the client does not allow",
            %{"negotiated" => version, "requested" => versions(allowed)}
          )
        )

      dialect ->
        session = %Session{
          version: version,
          id: session_id(headers),
          server_info: Map.get(result, "serverInfo", %{}),
          server_capabilities: Map.get(result, "capabilities", %{}),
          instructions: Map.get(result, "instructions")
        }

        client = %{speak(client, dialect) | session: session}

        case Client.notify(client, "notifications/initialized", %{}) do
          :ok -> {:ok, client}
          {:error, %Error{} = error} -> close_with(client, error)
        end
    end
  end

  # The transport calls the header function in this process before the
  # response is returned, so the message is already here.
  defp collect_headers(ref) do
    receive do
      {^ref, headers} -> headers
    after
      0 -> []
    end
  end

  defp session_id(headers) do
    Enum.find_value(headers, fn
      {"mcp-session-id", id} when is_binary(id) and id != "" -> id
      _other -> nil
    end)
  end

  defp close_with(client, %Error{} = error) do
    :ok = Client.close(client)
    {:error, error}
  end

  defp no_common_version(dialects, versions) do
    Error.invalid_params("The server supports none of the protocol versions the client allows", %{
      "requested" => versions(dialects),
      "supported" => versions
    })
  end

  defp speak(client, dialect),
    do: %{client | dialect: dialect, protocol: dialect.version(), session: nil}

  defp versions(dialects), do: Enum.map(dialects, & &1.version())
end
