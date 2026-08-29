defmodule MCP.Extensions.Tasks.RetryPolicy do
  @moduledoc """
  Immutable, JSON-safe retry timing for durable task work.

  A policy is an exact, finite list of delays. Entry zero is used for the
  first retry requested by an executor, entry one for the second, and so on.
  Persisting the expanded list keeps scheduling deterministic across releases
  and restarts; no runtime callback is re-evaluated after recovery.

  The empty policy returned by `none/0` is the default and never retries.
  Retry delays bound application-requested retries only. Re-delivery after an
  ambiguous runner or node failure remains part of the runner's at-least-once
  recovery contract and does not consume this list.
  """

  @version 1
  @max_delay_ms 4_294_967_295

  @type delay_ms :: non_neg_integer()
  @type t :: %__MODULE__{delays_ms: [delay_ms()]}

  @enforce_keys [:delays_ms]
  defstruct [:delays_ms]

  @doc "Returns the default policy, which never retries executor outcomes."
  @spec none() :: t()
  def none, do: %__MODULE__{delays_ms: []}

  @doc "Builds a policy from its exact retry delays."
  @spec new([delay_ms()]) :: {:ok, t()} | {:error, term()}
  def new(delays_ms) do
    policy = %__MODULE__{delays_ms: delays_ms}

    case validate(policy) do
      :ok -> {:ok, policy}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Builds an exact-delay policy or raises `ArgumentError`."
  @spec new!([delay_ms()]) :: t()
  def new!(delays_ms) do
    case new(delays_ms) do
      {:ok, policy} -> policy
      {:error, reason} -> raise ArgumentError, "invalid retry policy: #{inspect(reason)}"
    end
  end

  @doc "Builds `retries` entries with one fixed delay."
  @spec fixed(delay_ms(), non_neg_integer()) :: {:ok, t()} | {:error, term()}
  def fixed(delay_ms, retries) when is_integer(retries) and retries >= 0 do
    new(List.duplicate(delay_ms, retries))
  end

  def fixed(_delay_ms, _retries), do: {:error, :invalid_retry_count}

  @doc "Builds a fixed-delay policy or raises `ArgumentError`."
  @spec fixed!(delay_ms(), non_neg_integer()) :: t()
  def fixed!(delay_ms, retries) do
    case fixed(delay_ms, retries) do
      {:ok, policy} -> policy
      {:error, reason} -> raise ArgumentError, "invalid retry policy: #{inspect(reason)}"
    end
  end

  @doc """
  Expands a capped exponential policy into exact persisted delays.

  `:max_delay_ms` defaults to the largest portable timer delay supported by
  this package. The first retry uses `initial_delay_ms`, then each subsequent
  entry doubles until the cap is reached.
  """
  @spec exponential(delay_ms(), non_neg_integer(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def exponential(initial_delay_ms, retries, opts \\ [])

  def exponential(initial_delay_ms, retries, opts)
      when is_integer(initial_delay_ms) and initial_delay_ms >= 0 and
             initial_delay_ms <= @max_delay_ms and is_integer(retries) and retries >= 0 and
             is_list(opts) do
    with :ok <- validate_exponential_options(opts),
         max_delay_ms <- Keyword.get(opts, :max_delay_ms, @max_delay_ms),
         true <- initial_delay_ms <= max_delay_ms do
      delays =
        initial_delay_ms
        |> Stream.iterate(&min(&1 * 2, max_delay_ms))
        |> Enum.take(retries)

      new(delays)
    else
      false -> {:error, :initial_delay_exceeds_maximum}
      {:error, reason} -> {:error, reason}
    end
  end

  def exponential(_initial_delay_ms, _retries, _opts),
    do: {:error, :invalid_exponential_policy}

  @doc "Builds an exponential policy or raises `ArgumentError`."
  @spec exponential!(delay_ms(), non_neg_integer(), keyword()) :: t()
  def exponential!(initial_delay_ms, retries, opts \\ []) do
    case exponential(initial_delay_ms, retries, opts) do
      {:ok, policy} -> policy
      {:error, reason} -> raise ArgumentError, "invalid retry policy: #{inspect(reason)}"
    end
  end

  @doc "Returns the next persisted delay without modifying the policy."
  @spec next_delay(t(), non_neg_integer()) :: {:ok, delay_ms()} | :exhausted
  def next_delay(%__MODULE__{delays_ms: delays_ms}, retry_count)
      when is_integer(retry_count) and retry_count >= 0 do
    case Enum.fetch(delays_ms, retry_count) do
      {:ok, delay_ms} -> {:ok, delay_ms}
      :error -> :exhausted
    end
  end

  @doc "Validates a policy constructed locally or decoded by an adapter."
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{delays_ms: delays_ms}) when is_list(delays_ms) do
    if Enum.all?(delays_ms, &valid_delay?/1),
      do: :ok,
      else: {:error, :invalid_retry_delays}
  end

  def validate(%__MODULE__{}), do: {:error, :invalid_retry_delays}
  def validate(_policy), do: {:error, :invalid_retry_policy}

  @doc "Encodes a policy as a stable JSON-safe persistence map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = policy) do
    case validate(policy) do
      :ok -> %{"version" => @version, "delaysMs" => policy.delays_ms}
      {:error, reason} -> raise ArgumentError, "cannot encode retry policy: #{inspect(reason)}"
    end
  end

  @doc "Decodes and validates a persistence map produced by `to_map/1`."
  @spec from_map(term()) :: {:ok, t()} | {:error, term()}
  def from_map(%{"version" => @version, "delaysMs" => delays_ms} = encoded)
      when map_size(encoded) == 2 do
    new(delays_ms)
  end

  def from_map(%{"version" => version}) when version != @version do
    {:error, {:unsupported_retry_policy_version, version}}
  end

  def from_map(_encoded), do: {:error, :invalid_retry_policy_encoding}

  defp valid_delay?(delay_ms) do
    is_integer(delay_ms) and delay_ms >= 0 and delay_ms <= @max_delay_ms
  end

  defp validate_exponential_options(opts) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, :invalid_exponential_options}

      Keyword.keys(opts) -- [:max_delay_ms] != [] ->
        {:error, :invalid_exponential_options}

      not valid_delay?(Keyword.get(opts, :max_delay_ms, @max_delay_ms)) ->
        {:error, :invalid_max_delay}

      true ->
        :ok
    end
  end
end
