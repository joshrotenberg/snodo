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

  @runs 5

  defp best_time(template, uri) do
    {:ok, compiled} = Template.compile(template)

    1..@runs
    |> Enum.map(fn _run -> elem(:timer.tc(fn -> Template.match(compiled, uri) end), 0) end)
    |> Enum.min()
    |> max(1)
  end

  defp uri(bytes, segment),
    do: "x://h/" <> String.duplicate(segment <> "/", div(bytes, byte_size(segment) + 1)) <> "z"

  test "variable-length expressions cost about as much as one {var} on the same URI" do
    for segment <- ["a", "%41"] do
      uri = uri(1_000_000, segment)
      baseline = best_time("x://h/{a}", uri)

      for template <- ["x://h/{+p}", "x://h{/p*}", "x://h/{+p}/z"] do
        ratio = best_time(template, uri) / baseline

        assert ratio < 6,
               "#{template} took #{Float.round(ratio, 1)}x a single {var} on #{inspect(segment)} segments"
      end
    end
  end

  test "variable-length expressions grow linearly with the URI" do
    for template <- ["x://h/{+p}", "x://h{/p*}"] do
      small = best_time(template, uri(250_000, "a"))
      large = best_time(template, uri(1_000_000, "a"))

      # Four times the input; linear cost is a ratio near 4.
      assert large / small < 10,
             "#{template}: #{large} us for 1 MB against #{small} us for 250 KB"
    end
  end
end
