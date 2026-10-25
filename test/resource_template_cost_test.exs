defmodule Snodo.ResourceTemplateCostTest do
  @moduledoc """
  Guards the cost of matching variable-length path expressions. A `{+var}` or
  `{/var*}` match must stay within a small factor of a single-`{var}` template
  given the same URI, and must grow linearly with the URI. Validating or
  decoding segment by segment, or any backtracking, fails these bounds.
  """

  # Timing comparisons are steadier without other tests running alongside.
  use ExUnit.Case, async: false

  alias Snodo.Resource.Template

  @runs 7

  # The best of @runs timings for each {template, uri} pair. The pairs take
  # turns within each round, after a garbage collection, so load on a busy
  # machine slows each of them alike and a ratio between them stays meaningful.
  defp best_times(pairs) do
    compiled =
      Enum.map(pairs, fn {template, uri} ->
        {:ok, compiled} = Template.compile(template)
        {compiled, uri}
      end)

    1..@runs
    |> Enum.map(fn _run -> Enum.map(compiled, &time_match/1) end)
    |> Enum.zip_with(&Enum.min/1)
    |> Enum.map(&max(&1, 1))
  end

  defp time_match({template, uri}) do
    :erlang.garbage_collect()
    elem(:timer.tc(fn -> Template.match(template, uri) end), 0)
  end

  defp uri(bytes, segment),
    do: "x://h/" <> String.duplicate(segment <> "/", div(bytes, byte_size(segment) + 1)) <> "z"

  test "variable-length expressions cost about as much as one {var} on the same URI" do
    for segment <- ["a", "%41"] do
      uri = uri(1_000_000, segment)
      templates = ["x://h/{+p}", "x://h{/p*}", "x://h/{+p}/z"]
      [baseline | times] = best_times(for t <- ["x://h/{a}" | templates], do: {t, uri})

      for {template, time} <- Enum.zip(templates, times) do
        ratio = time / baseline

        assert ratio < 6,
               "#{template} took #{Float.round(ratio, 1)}x a single {var} on #{inspect(segment)} segments"
      end
    end
  end

  test "variable-length expressions grow linearly with the URI" do
    for template <- ["x://h/{+p}", "x://h{/p*}"] do
      [small, large] =
        best_times([{template, uri(250_000, "a")}, {template, uri(1_000_000, "a")}])

      # Four times the input; linear cost is a ratio near 4.
      assert large / small < 10,
             "#{template}: #{large} us for 1 MB against #{small} us for 250 KB"
    end
  end
end
