defmodule Snodo.FormatterTest do
  use ExUnit.Case, async: true

  setup_all do
    {options, _binding} = Code.eval_file(Path.expand("../.formatter.exs", __DIR__))
    [exports: Keyword.fetch!(options, :export)]
  end

  test "formatter exports cover every public DSL macro", %{exports: exports} do
    locals = Keyword.fetch!(exports, :locals_without_parens)

    for module <- Application.spec(:snodo, :modules),
        {name, arity} <- module.__info__(:macros),
        not String.starts_with?(Atom.to_string(name), "__") do
      assert {name, arity} in locals,
             "missing formatter export for #{inspect(module)}.#{name}/#{arity}"
    end
  end

  test "exported options preserve GenServer tool calls without parentheses", %{exports: exports} do
    for macro <- [:genserver_call, :genserver_cast] do
      source = "#{macro} \"counter\", target: Counter, message: :get"

      assert source |> Code.format_string!(exports) |> IO.iodata_to_binary() == source
    end
  end
end
