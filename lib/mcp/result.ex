defmodule MCP.Result do
  @moduledoc """
  A protocol-neutral handler result shaped later by the selected dialect.

  `error/2` builds a *successful* `tools/call` response carrying
  `isError: true`. That is what a failed upstream call, a rejected domain
  precondition, or any other outcome the tool itself understands should
  return. It is not the same as returning `{:error, %MCP.Error{}}` from a
  handler, which makes the whole JSON-RPC request fail. See `MCP.Tool` for
  which to reach for.

  Values handed to `structured/2` and to the content builders must be JSON
  values, meaning string keys and no atoms. `MCP.JSONValue.encodable!/1`
  converts an atom-keyed domain value into one.
  """

  alias MCP.Error

  @type kind ::
          :text
          | :structured
          | :resource
          | :tools
          | :resources
          | :resource_templates
          | :resource_read
          | :prompts
          | :prompt_get
          | :completion
          | :subscription
          | :error
          | :raw
          | :wire
  @type t :: %__MODULE__{
          kind: kind(),
          value: term(),
          error: Error.t() | nil,
          metadata: map()
        }

  @enforce_keys [:kind]
  defstruct [:kind, :value, :error, metadata: %{}]

  @spec text(String.t(), keyword()) :: t()
  def text(text, opts \\ []) when is_binary(text) do
    %__MODULE__{kind: :text, value: text, metadata: Keyword.get(opts, :metadata, %{})}
  end

  @spec structured(term(), keyword()) :: t()
  def structured(value, opts \\ []) do
    %__MODULE__{kind: :structured, value: value, metadata: Keyword.get(opts, :metadata, %{})}
  end

  @spec resource(term(), keyword()) :: t()
  def resource(contents, opts \\ []) do
    %__MODULE__{kind: :resource, value: contents, metadata: Keyword.get(opts, :metadata, %{})}
  end

  @spec tools([map()]) :: t()
  def tools(definitions), do: %__MODULE__{kind: :tools, value: definitions}

  @spec resources([term()]) :: t()
  def resources(definitions), do: %__MODULE__{kind: :resources, value: definitions}

  @spec resource_templates([term()]) :: t()
  def resource_templates(definitions),
    do: %__MODULE__{kind: :resource_templates, value: definitions}

  @spec resource_read([map()] | map(), keyword()) :: t()
  def resource_read(contents, opts \\ []) do
    %__MODULE__{
      kind: :resource_read,
      value: List.wrap(contents),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @spec prompts([term()]) :: t()
  def prompts(definitions), do: %__MODULE__{kind: :prompts, value: definitions}

  @spec prompt_get([map()] | map(), keyword()) :: t()
  def prompt_get(messages, opts \\ []) do
    %__MODULE__{
      kind: :prompt_get,
      value: %{
        messages: List.wrap(messages),
        description: Keyword.get(opts, :description)
      },
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc "Builds a ranked completion result with optional cardinality hints."
  @spec completion([String.t()], keyword()) :: t()
  def completion(values, opts \\ []) when is_list(values) and is_list(opts) do
    %__MODULE__{
      kind: :completion,
      value: %{
        values: values,
        total: Keyword.get(opts, :total),
        has_more: Keyword.get(opts, :has_more)
      },
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @spec raw(term()) :: t()
  def raw(value), do: %__MODULE__{kind: :raw, value: value}

  @doc false
  @spec subscription(MCP.Subscription.t()) :: t()
  def subscription(%MCP.Subscription{} = subscription) do
    %__MODULE__{kind: :subscription, value: subscription}
  end

  @doc """
  Marks a JSON object as an already dialect-shaped result.

  This escape hatch is intended for protocol dialects and negotiated extensions
  that add a polymorphic result shape to an existing core method. The selected
  dialect still stamps response metadata and the server still validates that the
  final JSON-RPC response is JSON-compatible.
  """
  @spec wire(map(), keyword()) :: t()
  def wire(value, opts \\ []) when is_map(value) and is_list(opts) do
    %__MODULE__{kind: :wire, value: value, metadata: Keyword.get(opts, :metadata, %{})}
  end

  @spec error(String.t(), keyword()) :: t()
  def error(message, opts \\ []) when is_binary(message) do
    error = Keyword.get_lazy(opts, :error, fn -> Error.execution(message) end)

    %__MODULE__{
      kind: :error,
      value: message,
      error: error,
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @spec normalize(t() | term()) :: t()
  def normalize(%__MODULE__{} = result), do: result
  def normalize(value) when is_binary(value), do: text(value)
  def normalize(value), do: structured(value)
end
