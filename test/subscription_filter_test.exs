defmodule Snodo.Subscription.FilterTest do
  use ExUnit.Case, async: true

  alias Snodo.Subscription.Filter

  test "subset checks stay linear in the length of list values" do
    uris = for n <- 1..50_000, do: "test://resource/#{n}"
    candidate = %{"resourceSubscriptions" => uris}
    supported = %{"resourceSubscriptions" => Enum.reverse(uris)}

    # A quadratic check takes minutes on 50,000 URIs.
    {elapsed, result} = :timer.tc(fn -> Filter.subset?(candidate, supported) end)

    assert result
    assert elapsed < 2_000_000
  end

  test "list values compare elements exactly" do
    assert Filter.subset?(%{"a" => [1, "x"]}, %{"a" => ["x", 1, 2]})
    refute Filter.subset?(%{"a" => [1.0]}, %{"a" => [1]})
    refute Filter.subset?(%{"a" => ["y"]}, %{"a" => ["x"]})
    assert Filter.project(%{"a" => ["x"], "b" => true}, %{"a" => ["x", "z"]}) == %{"a" => ["x"]}
  end
end
