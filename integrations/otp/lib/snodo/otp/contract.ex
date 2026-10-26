defmodule Snodo.OTP.Contract do
  @moduledoc """
  One module describes a GenServer's remote-callable operations for both
  sides. The server side (`Snodo.OTP.Server.expose/2`) turns it into
  `Snodo.Tool.GenServer` declarations: JSON in, Elixir message, reply term,
  JSON out. The client side (`Snodo.OTP.Proxy`) uses the inverse pair:
  Elixir message in, JSON out over the wire, JSON reply back to a term.

  Nothing is inferred. An operation exists because the contract names it,
  with its schema, which keeps the boundary the GenServer tool experiment
  settled on: a client never chooses a process, atom or term.
  """

  @type op :: %{
          required(:name) => String.t(),
          required(:kind) => :call | :cast,
          required(:input_schema) => map(),
          optional(:output_schema) => map(),
          optional(:description) => String.t(),
          optional(:timeout) => pos_integer()
        }

  @doc "The operations, in catalog order."
  @callback ops() :: [op()]

  @doc "Server side: validated JSON arguments to the GenServer message."
  @callback build_message(name :: String.t(), args :: map()) :: term()

  @doc "Server side: the GenServer reply to a JSON object."
  @callback encode_reply(name :: String.t(), reply :: term()) :: map()

  @doc "Client side: a GenServer.call message to an operation and JSON arguments, or :nomatch."
  @callback encode_call(message :: term()) :: {String.t(), map()} | :nomatch

  @doc "Client side: a GenServer.cast message to an operation and JSON arguments, or :nomatch."
  @callback encode_cast(message :: term()) :: {String.t(), map()} | :nomatch

  @doc "Client side: the JSON reply object back to the term the caller expects."
  @callback decode_reply(name :: String.t(), json :: map()) :: term()
end
