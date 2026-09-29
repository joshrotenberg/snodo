defmodule Snodo.Client.Deadline do
  @moduledoc false
  # The response deadline of one client request. With
  # `reset_timeout_on_progress: true`, each progress notification moves it to
  # `timeout` from now, but never past `max_total_timeout` from the start.

  alias Snodo.Client.Transport

  @default_max_total_timeout 600_000

  @enforce_keys [:timeout, :at]
  defstruct [:timeout, :at, :cap, :max_total_timeout, reset?: false, capped?: false]

  @type t :: %__MODULE__{
          timeout: timeout(),
          at: integer() | :infinity,
          cap: integer() | nil,
          max_total_timeout: pos_integer() | nil,
          reset?: boolean(),
          capped?: boolean()
        }

  @doc false
  def default_max_total_timeout, do: @default_max_total_timeout

  @doc false
  @spec new(keyword()) :: t()
  def new(opts) do
    timeout = Keyword.fetch!(opts, :timeout)
    reset? = Keyword.get(opts, :reset_timeout_on_progress, false)
    max_total = Keyword.get(opts, :max_total_timeout, @default_max_total_timeout)

    case timeout do
      :infinity ->
        %__MODULE__{timeout: :infinity, at: :infinity}

      timeout ->
        now = now()

        %__MODULE__{
          timeout: timeout,
          at: now + timeout,
          cap: now + max_total,
          max_total_timeout: max_total,
          reset?: reset?
        }
    end
  end

  @doc false
  @spec extend(t()) :: t()
  def extend(%__MODULE__{reset?: true, at: at, cap: cap} = deadline) when is_integer(at) do
    wanted = now() + deadline.timeout

    if wanted > cap and cap >= at,
      do: %{deadline | at: cap, capped?: true},
      else: %{deadline | at: max(at, min(wanted, cap))}
  end

  def extend(%__MODULE__{} = deadline), do: deadline

  @doc false
  @spec remaining(t()) :: timeout()
  def remaining(%__MODULE__{at: :infinity}), do: :infinity
  def remaining(%__MODULE__{at: at}), do: max(at - now(), 0)

  @doc false
  @spec error(t()) :: Snodo.Error.t()
  def error(%__MODULE__{capped?: true, max_total_timeout: max_total}),
    do: Transport.max_total_timeout_error(max_total)

  def error(%__MODULE__{timeout: timeout}), do: Transport.timeout_error(timeout)

  defp now, do: System.monotonic_time(:millisecond)
end
