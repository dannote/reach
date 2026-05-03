defmodule Reach.CLI.RemovedTasksTest do
  use ExUnit.Case

  alias Mix.Tasks.Reach.Modules

  test "removed compatibility tasks raise with migration guidance" do
    assert_raise Mix.Error,
                 ~r/mix reach.modules has been removed; use mix reach.map --modules/,
                 fn ->
                   Modules.run(["--format", "oneline", "--top", "1"])
                 end
  end
end
