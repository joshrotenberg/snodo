defmodule Snodo.Component.Wrap.Concurrency do
  @moduledoc """
  Limits concurrent executions of one declared component wrapper.

  The default `limit: 32` counts all callers together. Pass `key: fn context
  -> ... end` to count each returned key separately. Permits are released when
  the callback returns or its process ends.
  """

  @behaviour Snodo.Component.Wrap

  alias Snodo.Component.Wrap
  alias Snodo.Component.Wrap.State

  @default_limit 32

  @doc false
  def validate_options!(options, env) do
    limit = Keyword.get(options, :limit, @default_limit)
    key = Keyword.get(options, :key)

    unless Keyword.keys(options) -- [:limit, :key] == [] and is_integer(limit) and limit > 0 and
             (is_nil(key) or is_function(key, 1)) do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "concurrency wrapper requires a positive :limit and optional key/1"
    end

    :ok
  end

  @doc "Acquires a component permit before calling the next callback."
  @impl true
  def call(context, arguments, next, options) do
    kind = Keyword.fetch!(options, :kind)
    scope = {Keyword.fetch!(options, :component), Keyword.fetch!(options, :slot)}

    case Wrap.key(context, options) do
      {:ok, key} ->
        case acquire(scope, key, Keyword.get(options, :limit, @default_limit)) do
          {:ok, lease} ->
            try do
              next.(context, arguments)
            after
              release(lease)
            end

          {:error, :limited} ->
            Wrap.reject(kind, "Component concurrency limit reached")

          {:error, :unavailable} ->
            Wrap.reject(kind, "Component concurrency limiter unavailable")
        end

      {:error, :key_failed} ->
        Wrap.reject(kind, "Component concurrency key failed")
    end
  end

  defp acquire(scope, key, limit) do
    State.acquire(scope, key, limit, self())
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp release(lease) do
    State.release(lease)
  catch
    :exit, _reason -> :ok
  end
end
