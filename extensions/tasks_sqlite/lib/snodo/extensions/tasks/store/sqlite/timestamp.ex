defmodule Snodo.Extensions.Tasks.Store.SQLite.Timestamp do
  @moduledoc false

  @minimum -9_223_372_036_854_775_808
  @maximum 9_223_372_036_854_775_807

  @spec parse(term()) :: {:ok, integer()} | {:error, term()}
  def parse(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, datetime, _offset} -> bounded(DateTime.to_unix(datetime, :microsecond))
      {:error, _reason} -> {:error, :invalid_timestamp}
    end
  rescue
    ArgumentError -> {:error, :invalid_timestamp}
  end

  def parse(_timestamp), do: {:error, :invalid_timestamp}

  @spec optional(term()) :: {:ok, integer() | nil} | {:error, term()}
  def optional(nil), do: {:ok, nil}
  def optional(timestamp), do: parse(timestamp)

  @spec format(term()) :: {:ok, String.t()} | {:error, term()}
  def format(microseconds) when is_integer(microseconds) do
    with {:ok, bounded} <- bounded(microseconds),
         {:ok, datetime} <- DateTime.from_unix(bounded, :microsecond) do
      {:ok, DateTime.to_iso8601(datetime)}
    else
      {:error, _reason} -> {:error, :invalid_database_timestamp}
    end
  end

  def format(_microseconds), do: {:error, :invalid_database_timestamp}

  @spec add_milliseconds(integer(), non_neg_integer()) :: {:ok, integer()} | {:error, term()}
  def add_milliseconds(microseconds, milliseconds)
      when is_integer(microseconds) and is_integer(milliseconds) and milliseconds >= 0 do
    bounded(microseconds + milliseconds * 1_000)
  end

  def add_milliseconds(_microseconds, _milliseconds), do: {:error, :invalid_timestamp_addition}

  @spec successor(integer()) :: {:ok, integer()} | {:error, term()}
  def successor(microseconds) when is_integer(microseconds), do: bounded(microseconds + 1)
  def successor(_microseconds), do: {:error, :invalid_timestamp_addition}

  @spec bounded(term()) :: {:ok, integer()} | {:error, term()}
  def bounded(value) when is_integer(value) and value >= @minimum and value <= @maximum,
    do: {:ok, value}

  def bounded(_value), do: {:error, :timestamp_out_of_range}
end
