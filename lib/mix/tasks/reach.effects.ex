defmodule Mix.Tasks.Reach.Effects do
  @moduledoc """
  Effect classification summary — distribution of side effects
  across the codebase and calls the engine cannot classify.

  Every function call is classified by its side effect: `pure`,
  `io`, `read`, `write`, `send`, `receive`, `exception`, `nif`,
  or `unknown`. This command shows the distribution and highlights
  the top `unknown` calls — places where the engine cannot determine
  the effect, which may indicate missing domain knowledge.

      mix reach.effects
      mix reach.effects --format json
      mix reach.effects --module MyApp.UserController

  ## Options

    * `--format` — output format: `text` (default), `json`, `oneline`
    * `--module` — restrict to a specific module

  """

  use Mix.Task

  alias Reach.CLI.Format
  alias Reach.CLI.Project
  alias Reach.Effects
  alias Reach.IR

  @shortdoc "Effect classification distribution"

  @switches [format: :string, module: :string, graph: :boolean]
  @aliases [f: :format]

  @noise_functions [
    :@,
    :__aliases__,
    :|,
    :\\,
    :<<>>,
    :spec,
    :callback,
    :doc,
    :moduledoc,
    :sigil_s,
    :unquote,
    :quote,
    :defmacro,
    :alias,
    :"::"
  ]

  @impl Mix.Task
  def run(args) do
    {opts, args, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)
    format = opts[:format] || "text"
    path = List.first(args)

    project = Project.load()
    result = analyze(project, opts[:module] || path)

    if opts[:graph] do
      render_graph(result)
    else
      case format do
        "json" -> Format.render(result, "reach.effects", format: "json", pretty: true)
        "oneline" -> render_oneline(result)
        _ -> render_text(result)
      end
    end
  end

  defp analyze(project, module_filter) do
    nodes = Map.values(project.nodes)
    mod_defs = Enum.filter(nodes, &(&1.type == :module_def))

    call_nodes =
      nodes
      |> Enum.filter(&(&1.type == :call))
      |> filter_by_module(mod_defs, module_filter)

    distribution =
      call_nodes
      |> Enum.map(&Effects.classify/1)
      |> Enum.frequencies()
      |> Enum.sort_by(&elem(&1, 1), :desc)

    unknowns =
      call_nodes
      |> Enum.filter(&(Effects.classify(&1) == :unknown))
      |> Enum.reject(fn n ->
        is_nil(n.meta[:function]) or n.meta[:function] in @noise_functions
      end)
      |> Enum.map(fn n -> {n.meta[:module], n.meta[:function]} end)
      |> Enum.frequencies()
      |> Enum.sort_by(&elem(&1, 1), :desc)
      |> Enum.take(20)
      |> Enum.map(fn {{mod, fun}, count} ->
        %{
          module: if(mod, do: inspect(mod), else: "Kernel"),
          function: to_string(fun),
          count: count
        }
      end)

    total = length(call_nodes)

    %{
      total_calls: total,
      distribution:
        Enum.map(distribution, fn {effect, count} ->
          %{effect: to_string(effect), count: count, ratio: Float.round(count / max(total, 1), 3)}
        end),
      unknown_calls: unknowns
    }
  end

  defp filter_by_module(call_nodes, mod_defs, nil), do: filter_project_calls(call_nodes, mod_defs)

  defp filter_by_module(call_nodes, mod_defs, module_name) do
    mod_def =
      Enum.find(mod_defs, fn m ->
        to_string(m.meta[:name]) =~ module_name
      end)

    case mod_def do
      nil -> call_nodes
      m -> filter_project_calls(IR.all_nodes(m), mod_defs)
    end
  end

  defp filter_project_calls(nodes, mod_defs) do
    project_mod_ids =
      mod_defs
      |> Enum.flat_map(&IR.all_nodes/1)
      |> MapSet.new(& &1.id)

    Enum.filter(nodes, fn n ->
      n.type == :call and MapSet.member?(project_mod_ids, n.id)
    end)
  end

  # --- Rendering ---

  defp render_text(result) do
    IO.puts(Format.header("Effect Distribution (#{result.total_calls} calls)"))

    Enum.each(result.distribution, fn %{effect: effect, count: count, ratio: ratio} ->
      pct = Float.round(ratio * 100, 1)
      count_str = String.pad_leading(to_string(count), 6)
      pct_str = String.pad_leading("#{pct}%", 6)

      IO.puts(
        "  #{effect_color(effect, String.pad_trailing(effect, 12))} #{count_str}  #{Format.faint(pct_str)}"
      )
    end)

    if result.unknown_calls != [] do
      IO.puts(Format.section("Top Unknown-Effect Calls"))

      Enum.each(result.unknown_calls, fn u ->
        IO.puts("  #{Format.yellow("#{u.module}.#{u.function}")}  ×#{u.count}")
      end)
    end

    IO.puts("")
  end

  defp render_oneline(result) do
    Enum.each(result.distribution, fn %{effect: effect, count: count} ->
      IO.puts("effect:#{effect}\t#{count}")
    end)

    Enum.each(result.unknown_calls, fn u ->
      IO.puts("unknown:#{u.module}.#{u.function}\t#{u.count}")
    end)
  end

  defp render_graph(result) do
    unless Code.ensure_loaded?(Boxart.Render.PieChart) do
      Mix.raise("boxart is required for --graph. Add {:boxart, \"~> 0.3\"} to your deps.")
    end

    alias Boxart.Render.PieChart
    alias PieChart.PieChart, as: PC

    slices =
      result.distribution
      |> Enum.reject(&(&1.count == 0))
      |> Enum.map(&{&1.effect, &1.ratio * 100})

    chart = %PC{
      title: "Effect Distribution (#{result.total_calls} calls)",
      slices: slices,
      show_data: true
    }

    IO.puts(PieChart.render(chart))
  end

  defp effect_color("pure", text), do: Format.green(text)
  defp effect_color("io", text), do: Format.yellow(text)
  defp effect_color("write", text), do: Format.red(text)
  defp effect_color("read", text), do: Format.cyan(text)
  defp effect_color("send", text), do: Format.yellow(text)
  defp effect_color("receive", text), do: Format.yellow(text)
  defp effect_color("exception", text), do: Format.red(text)
  defp effect_color("nif", text), do: Format.red(text)
  defp effect_color("unknown", text), do: Format.faint(text)
  defp effect_color(_, text), do: text
end
