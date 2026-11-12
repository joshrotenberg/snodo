unless Node.alive?() do
  if epmd = System.find_executable("epmd"), do: System.cmd(epmd, ["-daemon"])
  name = :"snodo_test_#{System.unique_integer([:positive])}"

  case :net_kernel.start([name, :shortnames]) do
    {:ok, _pid} ->
      :ok

    {:error, reason} ->
      message = "Erlang distribution unavailable: #{inspect(reason)}"

      if System.get_env("CI") do
        raise message
      else
        IO.puts(:stderr, message <> "; distributed tests will skip")
      end
  end
end

ExUnit.start(assert_receive_timeout: 1_000)
