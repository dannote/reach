defmodule Mix.Tasks.Reach.SliceTest do
  use ExUnit.Case

  alias Mix.Tasks.Reach.Slice

  test "removed task points to reach.trace" do
    assert_raise Mix.Error,
                 ~r/mix reach.slice TARGET has been removed; use mix reach.trace TARGET/,
                 fn ->
                   Slice.run(["lib/reach/project.ex:1"])
                 end
  end
end
