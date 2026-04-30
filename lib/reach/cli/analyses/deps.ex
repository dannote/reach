defmodule Reach.CLI.Analyses.Deps do
  @moduledoc """
  Shows what a function depends on — direct and transitive callers, callees,
  and shared state.

      mix reach.deps UserService.register/2
      mix reach.deps lib/my_app/user_service.ex:10
      mix reach.deps UserService.register/2 --format json

  ## Options

    * `--format` — output format: `text` (default), `json`, `oneline`
    * `--depth` — transitive depth (default: 3)

  """

  @switches [format: :string, depth: :integer, graph: :boolean]
  @aliases [f: :format]

  alias Reach.CLI.BoxartGraph
  alias Reach.CLI.Format
  alias Reach.CLI.Project

  def run(args) do
    {opts, target_args, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    unless target_args != [] do
      Mix.raise(
        "Expected a target. Usage:\n" <>
          "  mix reach.deps Module.function/arity\n" <>
          "  mix reach.deps lib/foo.ex:42"
      )
    end

    project = Project.load(quiet: opts[:format] == "json")
    target = Project.resolve_target(project, hd(target_args))

    unless target do
      Mix.raise("Function not found: #{hd(target_args)}")
    end

    format = opts[:format] || "text"
    depth = opts[:depth] || 3

    caller_list = Project.callers(project, target, 1)
    callee_tree = Project.callees(project, target, depth)
    shared = find_shared_state(project, target)

    result = %{
      target: target,
      callers: caller_list,
      callees: callee_tree,
      shared_state_writers: shared
    }

    render_output(format, result, project, target, depth, opts)
  end

  defp render_output(format, result, project, target, depth, opts) do
    if opts[:graph] do
      BoxartGraph.require!()
      BoxartGraph.render_call_graph(project, target, depth)
    else
      case format do
        "json" -> Format.render(result, "reach.deps", format: "json", pretty: true)
        "oneline" -> render_oneline(result)
        _ -> render_text(result)
      end
    end
  end

  defp find_shared_state(project, target) do
    nodes = project.nodes
    {_mod, fun, arity} = target

    all_func_defs = Map.values(nodes)

    target_calls =
      all_func_defs
      |> Enum.filter(fn n ->
        n.type == :function_def and
          n.meta[:name] == fun and n.meta[:arity] == arity
      end)
      |> Enum.flat_map(&Reach.IR.all_nodes/1)
      |> Enum.filter(fn n -> n.type == :call and Reach.Effects.classify(n) in [:write, :read] end)
      |> Enum.map(& &1.meta[:function])

    all_func_defs
    |> Enum.filter(fn n ->
      n.type == :function_def and {n.meta[:name], n.meta[:arity]} != {fun, arity} and
        n
        |> Reach.IR.all_nodes()
        |> Enum.any?(fn c ->
          c.type == :call and Reach.Effects.classify(c) == :write and
            c.meta[:function] in target_calls
        end)
    end)
    |> Enum.map(&{&1.meta[:module], &1.meta[:name], &1.meta[:arity]})
  end

  defp render_text(result) do
    target_str = Format.func_id_to_string(result.target)
    IO.puts(Format.header(target_str))

    IO.puts(Format.section("Callers"))

    case result.callers do
      [] ->
        IO.puts("  (no callers found)")

      callers ->
        Enum.each(callers, fn %{id: id} ->
          IO.puts("  #{Format.func_id_to_string(id)}")
        end)
    end

    IO.puts(Format.section("Callees"))
    render_callee_tree(result.callees, "")

    IO.puts(Format.section("Shared state writers"))

    case result.shared_state_writers do
      [] ->
        IO.puts("  (none found)")

      writers ->
        Enum.each(writers, &IO.puts("  #{Format.func_id_to_string(&1)}  #{Format.tag(:warning)}"))
    end

    n = length(result.callers)
    risk = if(n > 5, do: "HIGH", else: if(n > 2, do: "MEDIUM", else: "LOW"))
    IO.puts("\n#{n} caller(s), risk: #{risk}\n")
  end

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
