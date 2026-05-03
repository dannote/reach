defmodule Reach.CLI.Options do
  @moduledoc false

  def parse(args, switches, aliases \\ []) do
    {opts, positional, _invalid} = OptionParser.parse(args, switches: switches, aliases: aliases)
    {opts, positional}
  end

  def run(args, switches, aliases, fun) when is_function(fun, 2) do
    {opts, positional} = parse(args, switches, aliases)
    fun.(opts, positional)
  end
end
