defmodule Mix.Tasks.Reach.ImpactTest do
  use ExUnit.Case

  alias Mix.Tasks.Reach.Impact

  test "removed task points to reach.inspect --impact" do
    assert_raise Mix.Error,
                 ~r/mix reach.impact TARGET has been removed; use mix reach.inspect TARGET --impact/,
                 fn ->
                   Impact.run(["Reach.Project.from_mix_project/0"])
                 end
  end
end
