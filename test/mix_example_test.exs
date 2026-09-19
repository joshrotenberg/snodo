defmodule MCP.MixExampleTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Mcp.Example

  @environment_keys ["MIX_ENV", "MIX_BUILD_PATH", "MCP_EX_EXPECTED_BUILD_PATH"]

  setup do
    shell = Mix.shell()
    environment = Enum.map(@environment_keys, &{&1, System.get_env(&1)})
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(shell)

      Enum.each(environment, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  test "child keeps the resolved project environment and build path without MIX_ENV" do
    build_path = Path.expand(Mix.Project.build_path())
    System.delete_env("MIX_ENV")
    System.put_env("MCP_EX_EXPECTED_BUILD_PATH", build_path)

    assert Mix.env() == :test

    for inherited_path <- [build_path, Path.join([build_path, "..", Path.basename(build_path)])] do
      System.put_env("MIX_BUILD_PATH", inherited_path)
      assert Path.expand(Mix.Project.build_path()) == build_path
      Mix.Task.run("mcp.example", [fixture("environment.fixture")])
      assert_received {:mix_shell, :info, ["example environment: ok"]}
    end
  end

  test "non-zero child exit fails the task" do
    assert_raise Mix.Error, ~r/failed with status 7/, fn ->
      Example.run([fixture("failure.fixture")])
    end
  end

  test "compiler warnings fail the child check" do
    assert_raise Mix.Error, ~r/example emitted compiler warnings/, fn ->
      Example.run([fixture("warning.fixture")])
    end
  end

  test "invalid arguments and missing files fail before starting a child" do
    assert_raise Mix.Error, "usage: mix mcp.example PATH", fn ->
      Example.run([])
    end

    assert_raise Mix.Error, ~r/example file was not found/, fn ->
      Example.run([fixture("missing.fixture")])
    end
  end

  defp fixture(name), do: Path.join([__DIR__, "fixtures", "mix_example", name])
end
