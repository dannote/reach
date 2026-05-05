defmodule Reach.CLI.Render.Inspect.Deps do
  @moduledoc false

  alias Reach.CLI.Format

  def render(result, "json", command) do
    Format.render(result, command, format: "json", pretty: true)
  end

  def render(result, "oneline", _command), do: render_oneline(result)

  def render(result, _format, _command), do: render_text(result)

  defp render_text(result) do
    target_str = Format.func_id_to_string(result.target)
    IO.puts(Format.header(target_str))

    IO.puts(Format.section("Callers"))
    render_callers(result.callers)

    IO.puts(Format.section("Callees"))
    render_callee_tree(result.callees, "")

    IO.puts(Format.section("Shared state writers"))
    render_shared_state_writers(result.shared_state_writers)

    n = length(result.callers)
    risk = if(n > 5, do: "HIGH", else: if(n > 2, do: "MEDIUM", else: "LOW"))
    IO.puts("\n#{n} caller(s), risk: #{risk}\n")
  end

  defp render_callers([]), do: IO.puts("  " <> Format.empty("no callers"))

  defp render_callers(callers) do
    Enum.each(callers, fn %{id: id} ->
      IO.puts("  #{Format.func_id_to_string(id)}")
    end)
  end

  defp render_shared_state_writers([]), do: IO.puts("  " <> Format.empty())

  defp render_shared_state_writers(writers) do
    Enum.each(writers, &IO.puts("  #{Format.func_id_to_string(&1)}  #{Format.tag(:warning)}"))
  end

  defp render_callee_tree([], ""), do: IO.puts("  " <> Format.empty())
  defp render_callee_tree([], _prefix), do: nil

  defp render_callee_tree(items, prefix) do
    sorted = Enum.sort_by(items, &Format.func_id_to_string(&1.id))
    count = length(sorted)

    sorted
    |> Enum.with_index()
    |> Enum.each(fn {item, idx} ->
      last? = idx == count - 1
      connector = if last?, do: "└── ", else: "├── "
      child_prefix = if last?, do: "    ", else: "│   "
      IO.puts("#{prefix}#{connector}#{Format.func_id_to_string(item.id)}")
      render_callee_tree(item.children, "#{prefix}#{child_prefix}")
    end)
  end

  defp render_oneline(result) do
    target_str = Format.func_id_to_string(result.target)

    Enum.each(result.callers, fn %{id: id} ->
      IO.puts("#{target_str} ← #{Format.func_id_to_string(id)}")
    end)

    Enum.each(result.shared_state_writers, fn id ->
      IO.puts("#{target_str} shared_state #{Format.func_id_to_string(id)}")
    end)
  end
end
