defmodule Snodo.TasksMemoryStoreContractTest do
  use ExUnit.Case, async: true

  use Snodo.Extensions.Tasks.Store.ContractTest,
    start_store: &__MODULE__.start_contract_store/2

  @moduletag :tasks_package

  alias Snodo.Extensions.Tasks.Store.Memory

  @doc false
  def start_contract_store(_context, opts) do
    options =
      Keyword.merge([scope: fn context -> context.auth["tenant"] end], opts)

    server = start_supervised!({Memory, options}, id: {Memory, make_ref()})
    {Memory, server}
  end
end

defmodule Snodo.TasksDetsStoreContractTest do
  use ExUnit.Case, async: false

  use Snodo.Extensions.Tasks.Store.ContractTest,
    start_store: &__MODULE__.start_contract_store/2

  @moduletag :tasks_package

  alias Snodo.Extensions.Tasks.Store.Dets

  @doc false
  def start_contract_store(_context, opts) do
    unique = System.unique_integer([:positive])
    path = Path.join(System.tmp_dir!(), "snodo-contract-#{unique}.dets")
    table = String.to_atom("snodo_contract_#{unique}")

    options =
      Keyword.merge(
        [path: path, table: table, scope: fn context -> context.auth["tenant"] end],
        opts
      )

    server = start_supervised!({Dets, options}, id: {Dets, make_ref()})
    on_exit(fn -> File.rm(path) end)
    {Dets, server}
  end
end
