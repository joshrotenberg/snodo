defmodule Snodo.Component.Wrap.RateLimit do
  @moduledoc """
  Applies a fixed-window rate limit to one declared component wrapper.

  Defaults are `limit: 60`, `window_ms: 60_000`, and `max_keys: 10_000`.
  Without `key: fn context -> ... end`, all callers share one bucket. Expired
  keys are pruned when the per-wrapper key capacity is reached; a new key is
  refused if the capacity is still full.
  """

  @behaviour Snodo.Component.Wrap

  alias Snodo.Component.Wrap
  alias Snodo.Component.Wrap.State

  @default_limit 60
  @default_window_ms 60_000
  @default_max_keys 10_000

  @doc false
  def validate_options!(options, env) do
    bounds = [
      limit: @default_limit,
      window_ms: @default_window_ms,
      max_keys: @default_max_keys
    ]

    valid_bounds? =
      Enum.all?(bounds, fn {name, default} ->
        value = Keyword.get(options, name, default)
        is_integer(value) and value > 0
      end)

    key = Keyword.get(options, :key)

    unless Keyword.keys(options) -- [:limit, :window_ms, :max_keys, :key] == [] and
             valid_bounds? and (is_nil(key) or is_function(key, 1)) do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "rate wrapper requires positive :limit, :window_ms, and :max_keys"
    end

    :ok
  end

  @doc "Consumes one call from the current key's window before continuing."
  @impl true
  def call(context, arguments, next, options) do
    kind = Keyword.fetch!(options, :kind)
    scope = {Keyword.fetch!(options, :component), Keyword.fetch!(options, :slot)}

    case Wrap.key(context, options) do
      {:ok, key} ->
        result =
          consume(
            scope,
            key,
            Keyword.get(options, :limit, @default_limit),
            Keyword.get(options, :window_ms, @default_window_ms),
            Keyword.get(options, :max_keys, @default_max_keys)
          )

        case result do
          :ok -> next.(context, arguments)
          {:error, :limited} -> Wrap.reject(kind, "Component rate limit reached")
          {:error, :capacity} -> Wrap.reject(kind, "Component rate key capacity reached")
          {:error, :unavailable} -> Wrap.reject(kind, "Component rate limiter unavailable")
        end

      {:error, :key_failed} ->
        Wrap.reject(kind, "Component rate key failed")
    end
  end

  defp consume(scope, key, limit, window_ms, max_keys) do
    State.consume(scope, key, limit, window_ms, max_keys)
  catch
    :exit, _reason -> {:error, :unavailable}
  end
end
