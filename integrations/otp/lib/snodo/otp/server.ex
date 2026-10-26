defmodule Snodo.OTP.Server do
  @moduledoc """
  `expose Contract, target: Module` inside a `Snodo.Server` emits one
  `genserver_call`/`genserver_cast` declaration per contract operation, so
  the existing `Snodo.Tool.GenServer` adapter does the serving: schema
  validation, bounded call, tool errors for missing targets and timeouts.
  """

  defmacro expose(contract_ast, opts) do
    contract = Macro.expand(contract_ast, __CALLER__)
    target = Keyword.fetch!(opts, :target)
    Code.ensure_compiled!(contract)

    # Snodo.Tool.GenServer validates its options as a literal keyword list at
    # expansion time, so each declaration's list is built here whole.
    declarations = for op <- contract.ops(), do: declaration(contract, target, op)

    quote do
      require Snodo.Tool.GenServer
      unquote_splicing(declarations)
    end
  end

  defp declaration(contract, target, %{kind: :call, name: name} = op) do
    encode_reply =
      quote(do: fn reply -> unquote(contract).encode_reply(unquote(name), reply) end)

    options =
      base_options(contract, target, op) ++
        [encode_reply: encode_reply] ++
        optional(:output_schema, op[:output_schema] && Macro.escape(op.output_schema)) ++
        optional(:timeout, op[:timeout])

    quote do: Snodo.Tool.GenServer.genserver_call(unquote(name), unquote(options))
  end

  defp declaration(contract, target, %{kind: :cast, name: name} = op) do
    options = base_options(contract, target, op)
    quote do: Snodo.Tool.GenServer.genserver_cast(unquote(name), unquote(options))
  end

  defp base_options(contract, target, %{name: name} = op) do
    message = quote(do: fn args -> unquote(contract).build_message(unquote(name), args) end)

    [target: target, input_schema: Macro.escape(op.input_schema), message: message] ++
      optional(:description, op[:description])
  end

  defp optional(_key, nil), do: []
  defp optional(key, value), do: [{key, value}]
end
