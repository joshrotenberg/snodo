ExUnit.start(
  assert_receive_timeout: 1_000,
  exclude: [:distributed] ++ Keyword.get(ExUnit.configuration(), :exclude, [])
)

distributed? =
  Enum.any?(ExUnit.configuration()[:include], &(&1 in [:distributed, {:distributed, true}]))

if distributed? and not Node.alive?() do
  if epmd = System.find_executable("epmd"), do: System.cmd(epmd, ["-daemon"])
  name = List.to_atom(:peer.random_name(~c"snodo_test"))

  case :net_kernel.start([name, :shortnames]) do
    {:ok, _pid} ->
      :ok

    {:error, reason} ->
      message = "Erlang distribution unavailable: #{inspect(reason)}"

      if System.get_env("CI") in ["true", "1"] do
        raise message
      else
        IO.puts(:stderr, message <> "; distributed tests will skip")
      end
  end
end
