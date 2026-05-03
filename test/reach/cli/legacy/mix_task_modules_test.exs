defmodule Mix.Tasks.Reach.ModulesTest do
  use ExUnit.Case

  alias Mix.Tasks.Reach.Modules

  test "removed task points to reach.map --modules" do
    assert_raise Mix.Error,
                 ~r/mix reach.modules has been removed; use mix reach.map --modules/,
                 fn ->
                   Modules.run(["--top", "2"])
                 end
  end
end
