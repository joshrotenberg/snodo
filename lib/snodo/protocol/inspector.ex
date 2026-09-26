defmodule Snodo.Protocol.Inspector do
  @moduledoc """
  Pure exact-profile admission checks performed before semantic routing.

  `Snodo.Envelope` owns JSON-RPC structure. This module adds MCP method kind,
  direction, params presence, request metadata presence, and method-specific
  parameter checks for one immutable profile.
  """

  alias Snodo.Envelope
  alias Snodo.Error
  alias Snodo.Protocol.Inspection
  alias Snodo.Protocol.Profile
  alias Snodo.Protocol.Profile.Method

  @type direction :: :client_to_server | :server_to_client

  @doc false
  @spec inspect(Profile.t(), Envelope.t(), direction()) ::
          {:ok, Inspection.t()} | {:error, Error.t()}
  def inspect(%Profile{} = profile, %Envelope{} = envelope, direction)
      when direction in [:client_to_server, :server_to_client] do
    with :ok <- inspect_metadata(profile, envelope),
         {:ok, method, classification} <- classify_method(profile, envelope, direction),
         :ok <- inspect_rule(method, envelope, direction) do
      {:ok,
       %Inspection{
         profile: profile,
         envelope: envelope,
         method: method,
         direction: direction,
         classification: classification
       }}
    end
  end

  @doc "Inspects one externally registered exact method rule."
  @spec inspect_method(Method.t(), Envelope.t(), direction()) :: :ok | {:error, Error.t()}
  def inspect_method(%Method{} = method, %Envelope{} = envelope, direction)
      when direction in [:client_to_server, :server_to_client] do
    inspect_rule(method, envelope, direction)
  end

  defp inspect_metadata(profile, %Envelope{kind: kind, params: params}) do
    case {Profile.metadata_policy(profile, kind), Map.fetch(params, "_meta")} do
      {:required, :error} ->
        {:error, Error.invalid_params("Required request _meta is missing")}

      {_policy, {:ok, metadata}} when not is_map(metadata) ->
        {:error, Error.invalid_params("_meta must be an object")}

      _present_or_optional ->
        :ok
    end
  end

  defp classify_method(profile, %Envelope{method: name}, direction) do
    case Profile.fetch_method(profile, name, direction) do
      {:ok, %Method{status: :implemented} = method} ->
        {:ok, method, :implemented}

      {:ok, %Method{status: :unsupported} = method} ->
        {:ok, method, :unsupported}

      :error ->
        classify_other_direction_or_extension(profile, name)
    end
  end

  defp classify_other_direction_or_extension(profile, name) do
    case Profile.fetch_method(profile, name) do
      {:ok, %Method{status: :implemented} = method} -> {:ok, method, :implemented}
      {:ok, %Method{status: :unsupported} = method} -> {:ok, method, :unsupported}
      :error -> {:ok, nil, :extension}
    end
  end

  defp inspect_rule(nil, %Envelope{}, _direction), do: :ok

  defp inspect_rule(%Method{} = method, %Envelope{} = envelope, direction) do
    with :ok <- inspect_placement(method),
         :ok <- inspect_kind(method, envelope),
         :ok <- inspect_direction(method, direction),
         :ok <- inspect_params_presence(method, envelope) do
      run_validator(method, envelope.params)
    end
  end

  defp inspect_placement(%Method{placement: :top_level}), do: :ok

  defp inspect_placement(%Method{name: name, placement: :mrtr_embedded}) do
    {:error, Error.invalid_request("#{name} is only valid as an embedded MRTR input request")}
  end

  defp inspect_kind(%Method{kind: kind}, %Envelope{kind: kind}), do: :ok

  defp inspect_kind(%Method{} = method, %Envelope{} = envelope) do
    {:error,
     Error.invalid_request("#{method.name} must be a #{method.kind}, received #{envelope.kind}")}
  end

  defp inspect_direction(%Method{directions: directions}, direction) do
    if direction in directions,
      do: :ok,
      else: {:error, Error.invalid_request("Method is not available in this direction")}
  end

  defp inspect_params_presence(%Method{params: :optional}, %Envelope{}), do: :ok

  defp inspect_params_presence(%Method{params: :required}, %Envelope{raw: raw}) do
    if Map.has_key?(raw, "params"),
      do: :ok,
      else: {:error, Error.invalid_params("Required method params are missing")}
  end

  defp run_validator(%Method{validator: nil}, _params), do: :ok

  defp run_validator(%Method{validator: {module, function}}, params) do
    case apply(module, function, [params]) do
      :ok ->
        :ok

      {:error, message} when is_binary(message) ->
        {:error, Error.invalid_params(message)}

      other ->
        {:error, Error.internal("Protocol profile validator returned an invalid result", other)}
    end
  rescue
    exception ->
      Error.internal("Protocol profile validator raised", {exception, __STACKTRACE__})
      |> then(&{:error, &1})
  catch
    kind, reason ->
      Error.internal("Protocol profile validator terminated", {kind, reason, __STACKTRACE__})
      |> then(&{:error, &1})
  end
end
