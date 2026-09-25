defmodule Snodo.Completion do
  @moduledoc """
  A normalized, protocol-neutral completion request.

  Completion callbacks receive the registered prompt or resource-template
  reference, the argument being completed, its partial value, and any
  previously resolved string arguments. Protocol dialects remain responsible
  for translating their wire representation into this shape.
  """

  alias Snodo.Error
  alias Snodo.Result

  @type reference_type :: :prompt | :resource_template
  @type t :: %__MODULE__{
          reference_type: reference_type(),
          reference: String.t(),
          argument: String.t(),
          value: String.t(),
          arguments: %{optional(String.t()) => String.t()}
        }

  @enforce_keys [:reference_type, :reference, :argument, :value]
  defstruct [:reference_type, :reference, :argument, :value, arguments: %{}]

  @doc false
  @spec parse(map()) :: {:ok, t()} | {:error, Error.t()}
  def parse(params) when is_map(params) do
    with {:ok, {reference_type, reference}} <- parse_reference(params),
         {:ok, {argument, value}} <- parse_argument(params),
         {:ok, arguments} <- parse_context(params) do
      {:ok,
       %__MODULE__{
         reference_type: reference_type,
         reference: reference,
         argument: argument,
         value: value,
         arguments: arguments
       }}
    end
  end

  def parse(_params), do: {:error, Error.invalid_params("Completion params must be an object")}

  @doc false
  @spec validate_result(Result.t()) :: :ok | {:error, term()}
  def validate_result(%Result{
        kind: :completion,
        value: %{values: values, total: total, has_more: has_more}
      }) do
    with :ok <- validate_values(values),
         :ok <- validate_total(total, length(values)) do
      validate_has_more(has_more)
    end
  end

  def validate_result(%Result{kind: :completion}), do: {:error, :invalid_completion_value}
  def validate_result(%Result{}), do: {:error, :wrong_result_kind}

  defp parse_reference(%{"ref" => %{"type" => "ref/prompt", "name" => name} = reference})
       when is_binary(name) and name != "" do
    case Map.fetch(reference, "title") do
      {:ok, title} when not is_binary(title) ->
        {:error, Error.invalid_params("Completion prompt reference title must be a string")}

      _title_or_absent ->
        {:ok, {:prompt, name}}
    end
  end

  defp parse_reference(%{
         "ref" => %{"type" => "ref/resource", "uri" => uri}
       })
       when is_binary(uri) and uri != "" do
    {:ok, {:resource_template, uri}}
  end

  defp parse_reference(%{"ref" => %{"type" => type}}) when is_binary(type) do
    {:error, Error.invalid_params("Completion reference type is not supported")}
  end

  defp parse_reference(_params) do
    {:error, Error.invalid_params("Completion requires a prompt or resource-template reference")}
  end

  defp parse_argument(%{
         "argument" => %{"name" => name, "value" => value}
       })
       when is_binary(name) and name != "" and is_binary(value) do
    {:ok, {name, value}}
  end

  defp parse_argument(_params) do
    {:error, Error.invalid_params("Completion argument requires string name and value")}
  end

  defp parse_context(params) do
    case Map.fetch(params, "context") do
      :error ->
        {:ok, %{}}

      {:ok, context} when is_map(context) ->
        parse_context_arguments(context)

      {:ok, _invalid} ->
        {:error, Error.invalid_params("Completion context must be an object")}
    end
  end

  defp parse_context_arguments(%{"arguments" => arguments}) when is_map(arguments) do
    validate_context_argument_map(arguments)
  end

  defp parse_context_arguments(%{"arguments" => _invalid}) do
    {:error, Error.invalid_params("Completion context arguments must be an object")}
  end

  defp parse_context_arguments(_context), do: {:ok, %{}}

  defp validate_context_argument_map(arguments) do
    if Enum.all?(arguments, fn {key, value} -> is_binary(key) and is_binary(value) end),
      do: {:ok, arguments},
      else:
        {:error, Error.invalid_params("Completion context arguments must map strings to strings")}
  end

  defp validate_values(values) when not is_list(values), do: {:error, :values_must_be_a_list}
  defp validate_values(values) when length(values) > 100, do: {:error, :too_many_values}

  defp validate_values(values) do
    if Enum.all?(values, &is_binary/1),
      do: :ok,
      else: {:error, :values_must_be_strings}
  end

  defp validate_total(nil, _returned_count), do: :ok

  defp validate_total(total, returned_count)
       when is_integer(total) and total >= returned_count,
       do: :ok

  defp validate_total(total, _returned_count) when is_integer(total) and total >= 0,
    do: {:error, :total_must_cover_returned_values}

  defp validate_total(_total, _returned_count),
    do: {:error, :total_must_be_a_non_negative_integer}

  defp validate_has_more(has_more) when is_nil(has_more) or is_boolean(has_more), do: :ok
  defp validate_has_more(_has_more), do: {:error, :has_more_must_be_a_boolean}
end
