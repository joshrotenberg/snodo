defmodule Snodo.CancellationTest do
  use ExUnit.Case, async: true

  alias Snodo.Cancellation

  test "cancel/1 cancels every copy of a token" do
    token = Cancellation.new()
    copy = token
    refute Cancellation.cancelled?(copy)

    assert :ok = Cancellation.cancel(token)
    assert :ok = Cancellation.cancel(token)
    assert Cancellation.cancelled?(copy)
  end

  test "cancel/2 is deprecated because the token keeps no reason" do
    assert {{:cancel, 2}, message} =
             List.keyfind(Cancellation.__info__(:deprecated), {:cancel, 2}, 0)

    assert message =~ "use cancel/1"
  end
end
