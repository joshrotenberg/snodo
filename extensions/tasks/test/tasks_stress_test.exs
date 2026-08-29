defmodule MCP.TasksStressTest do
  use ExUnit.Case, async: false

  @moduletag :tasks_package

  alias MCP.Extensions.Tasks.Stress

  test "contention and runner soak produce exact invariant evidence" do
    report = Stress.run(tasks: 4, writers: 5, rounds: 3, timeout_ms: 5_000)

    assert report["ok"]
    assert Enum.all?(report["invariants"], fn {_name, passed?} -> passed? end)

    assert %{
             "applied" => 4,
             "attempts" => 20,
             "committedEvents" => 4,
             "conflicts" => 16,
             "terminalTasks" => 4,
             "unexpected" => 0
           } = report["scenarios"]["casContention"]

    runner = report["scenarios"]["runnerSoak"]
    assert runner["expectedJobs"] == 12
    assert runner["started"] == 12
    assert runner["stopped"] == 12
    assert runner["completed"] == 12
    assert runner["peakJobs"] == 4
    assert runner["finalJobs"] == 0
    assert runner["appliedTransitions"] == 12
    assert runner["otherTransitions"] == 0
    assert runner["durationUs"] > 0
    assert runner["observedJobDurationUs"] > 0
  end

  test "configuration rejects unknown and non-positive options" do
    assert_raise ArgumentError, ~r/:tasks must be a positive integer/, fn ->
      Stress.run(tasks: 0)
    end

    assert_raise ArgumentError, ~r/stress options must use only/, fn ->
      Stress.run(unknown: 1)
    end
  end
end
