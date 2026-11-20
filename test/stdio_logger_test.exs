defmodule Snodo.Transport.StdioLoggerTest do
  use ExUnit.Case, async: false

  alias Snodo.Transport.Stdio
  alias Snodo.Transport.Stdio.LoggerRedirect
  alias SnodoTest.TestFixtures
  alias SnodoTest.TestInput

  setup do
    previous = :logger.get_handler_config(:default)

    on_exit(fn ->
      _removed = :logger.remove_handler(:default)

      case previous do
        {:ok, %{module: module} = config} ->
          :ok = :logger.add_handler(:default, module, Map.drop(config, [:id, :module]))

        {:error, {:not_found, :default}} ->
          :ok
      end
    end)

    _removed = :logger.remove_handler(:default)

    :ok =
      :logger.add_handler(:default, :logger_std_h, %{
        config: %{type: :standard_io},
        level: :none
      })

    {:ok, original: handler()}
  end

  test "serve redirects stdout logging until EOF", %{original: original} do
    {server, input} = serve()

    assert %{config: %{type: :standard_error}} = handler()

    TestInput.eof(input)
    assert :ok = Task.await(server)
    assert handler() == original
  end

  test "an application change to the installed handler survives EOF" do
    {server, input} = serve()

    :ok = :logger.set_handler_config(:default, :level, :error)
    updated = handler()

    TestInput.eof(input)
    assert :ok = Task.await(server)
    assert handler() == updated
  end

  test "a handler removed while redirected stays removed after EOF" do
    {server, input} = serve()

    :ok = :logger.remove_handler(:default)

    TestInput.eof(input)
    assert :ok = Task.await(server)
    assert {:error, {:not_found, :default}} = :logger.get_handler_config(:default)
  end

  test "redirect_logger?: false leaves the handler alone", %{original: original} do
    {server, input} = serve(redirect_logger?: false)

    assert handler() == original

    TestInput.eof(input)
    assert :ok = Task.await(server)
    assert handler() == original
  end

  test "overlapping transports keep stderr until the last transport stops", %{original: original} do
    {first, first_input} = serve()
    {second, second_input} = serve()

    TestInput.eof(first_input)
    assert :ok = Task.await(first)
    assert %{config: %{type: :standard_error}} = handler()

    TestInput.eof(second_input)
    assert :ok = Task.await(second)
    assert handler() == original
  end

  test "the coordinator restores the handler after an untrappable exit", %{original: original} do
    {:ok, input} = TestInput.start_link()
    {:ok, server} = GenServer.start(Stdio, runtime: TestFixtures.runtime(), input: input)
    coordinator = Process.whereis(LoggerRedirect)
    %{owners: %{^server => monitor}} = :sys.get_state(coordinator)
    :erlang.trace(coordinator, true, [:receive])

    Process.exit(server, :kill)
    assert_receive {:trace, ^coordinator, :receive, {:DOWN, ^monitor, :process, ^server, :killed}}
    _state = :sys.get_state(coordinator)

    assert handler() == original
  end

  defp serve(opts \\ []) do
    {:ok, input} = TestInput.start_link()
    :erlang.trace(input, true, [:receive])

    task = Task.async(fn -> Stdio.serve(TestFixtures.runtime(), [input: input] ++ opts) end)

    assert_receive {:trace, ^input, :receive, {:io_request, _, _, {:get_line, _, _}}}
    :erlang.trace(input, false, [:receive])
    {task, input}
  end

  defp handler do
    {:ok, config} = :logger.get_handler_config(:default)
    config
  end
end
