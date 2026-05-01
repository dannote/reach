defmodule Reach.CLI.Analyses.Smell do
  @moduledoc """
  Finds local structural and performance smells.

  Detects redundant traversals, duplicate computations, eager Enum/List
  patterns, string-building patterns, and loose map contracts such as mixed
  atom/string key access.

      mix reach.smell
      mix reach.smell --format json
      mix reach.smell lib/my_app/

  ## Options

    * `--format` — output format: `text` (default), `json`, `oneline`

  """

  @switches [format: :string, path: :string]
  @aliases [f: :format]

  alias Reach.CLI.Analyses.Smell.Finding
  alias Reach.CLI.Format
  alias Reach.CLI.Project
  alias Reach.Effects
  alias Reach.IR

  def run(args) do
    {opts, args, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)
    format = opts[:format] || "text"
    path = opts[:path] || List.first(args)

    project_opts = [quiet: opts[:format] == "json"]
    project_opts = if path, do: Keyword.put(project_opts, :paths, [path]), else: project_opts
    project = Project.load(project_opts)

    findings = analyze(project)

    case format do
      "json" ->
        Format.render(%{findings: Enum.map(findings, &Finding.to_map/1)}, "reach.smell",
          format: "json",
          pretty: true
        )

      "oneline" ->
        Enum.each(findings, fn f ->
          IO.puts("#{f.location}: #{Format.yellow(to_string(f.kind))}: #{f.message}")
        end)

      _ ->
        render_text(findings)
    end
  end

  @doc false
  def analyze(project) do
    detect_redundant_computation(project) ++
      detect_string_building(project) ++
      run_checks(project)
  end

  # --- Redundant computation: same pure call twice with same args ---

  defp detect_redundant_computation(project) do
    nodes = Map.values(project.nodes)

    func_defs = Enum.filter(nodes, &(&1.type == :function_def))

    Enum.flat_map(func_defs, &find_redundant_calls_in_func/1)
    |> Enum.take(20)
  end

  @type_check_fns [
    :is_atom,
    :is_binary,
    :is_bitstring,
    :is_boolean,
    :is_exception,
    :is_float,
    :is_function,
    :is_integer,
    :is_list,
    :is_map,
    :is_map_key,
    :is_nil,
    :is_number,
    :is_pid,
    :is_port,
    :is_reference,
    :is_struct,
    :is_tuple
  ]

  defp find_redundant_calls_in_func(func) do
    # Walk each sequential block and find duplicate calls within
    # the same execution path (not across case/fn/cond clauses)
    func
    |> collect_sequential_blocks()
    |> Enum.flat_map(&find_redundant_in_block/1)
  end

  defp find_redundant_in_block(block_calls) do
    block_calls
    |> Enum.group_by(fn n -> {n.meta[:module], n.meta[:function], n.meta[:arity]} end)
    |> Enum.flat_map(fn {_key, group} ->
      if length(group) > 1, do: find_same_arg_calls(group), else: []
    end)
  end

  defp collect_sequential_blocks(node) do
    # For clause/block nodes, collect calls from the sequential body
    # (recursing into match/etc but not into case/fn branches)
    calls = collect_block_calls(node, []) |> Enum.reverse()

    # Recurse into case/fn/clause children to process each branch separately
    nested =
      (node.children || [])
      |> Enum.flat_map(fn child ->
        case child.type do
          t when t in [:case, :fn] ->
            child.children
            |> Enum.filter(&(&1.type == :clause))
            |> Enum.flat_map(&collect_sequential_blocks/1)

          :clause ->
            collect_sequential_blocks(child)

          _ ->
            []
        end
      end)

    if calls != [], do: [calls | nested], else: nested
  end

  @compiler_directives [
    :import,
    :alias,
    :require,
    :use,
    :doc,
    :moduledoc,
    :typedoc,
    :spec,
    :callback,
    :macrocallback,
    :impl,
    :type,
    :typep,
    :opaque,
    :behaviour,
    :defstruct,
    :defdelegate,
    :defmacro,
    :defmacrop,
    :defguard,
    :defguardp
  ]

  @pattern_operators [:|, :{}, :@]

  defp formatting_call?(%{meta: %{function: :to_string, module: Kernel}}), do: true
  defp formatting_call?(%{meta: %{function: :to_string, kind: :local}}), do: true
  defp formatting_call?(_), do: false

  defp redundancy_candidate?(node) do
    node.type == :call and Effects.pure?(node) and
      node.meta[:function] != nil and
      node.meta[:function] not in @type_check_fns and
      node.meta[:function] not in @compiler_directives and
      node.meta[:function] not in @pattern_operators and
      node.meta[:kind] not in [:attribute, :field_access] and
      not formatting_call?(node) and
      node.source_span != nil
  end

  defp collect_block_calls(node, acc) do
    acc = if redundancy_candidate?(node), do: [node | acc], else: acc

    node.children
    |> Enum.reject(&(&1.type in [:case, :fn, :clause]))
    |> Enum.reduce(acc, &collect_block_calls/2)
  end

  defp find_same_arg_calls(calls) do
    calls
    |> Enum.chunk_every(2, 1, [])
    |> Enum.flat_map(fn
      [a, b] -> maybe_redundant_call(a, b)
      _ -> []
    end)
  end

  defp maybe_redundant_call(a, b) do
    if same_args?(a, b) and a.source_span[:start_line] != b.source_span[:start_line] do
      [
        Finding.new(
          kind: :redundant_computation,
          message:
            "#{call_name(a)} called twice with same args (line #{a.source_span[:start_line]} and #{b.source_span[:start_line]})",
          location: Format.location(b)
        )
      ]
    else
      []
    end
  end

  defp same_args?(a, b) do
    length(a.children) == length(b.children) and a.children != [] and
      Enum.zip(a.children, b.children)
      |> Enum.all?(fn {ac, bc} -> same_node?(ac, bc) end)
  end

  defp same_node?(%{type: :var, meta: am}, %{type: :var, meta: bm}), do: am[:name] == bm[:name]

  defp same_node?(%{type: :literal, meta: am}, %{type: :literal, meta: bm}),
    do: am[:value] == bm[:value]

  defp same_node?(_, _), do: false

  defp call_name(node), do: Format.call_name(node)

  # --- Unused results: pure call whose return value is discarded ---

  # --- String building: detect string concat/interpolation where iolists would be better ---

  defp detect_string_building(project) do
    nodes = Map.values(project.nodes)
    func_defs = Enum.filter(nodes, &(&1.type == :function_def))
    Enum.flat_map(func_defs, &find_string_building_smells/1)
  end

  defp find_string_building_smells(func) do
    all = IR.all_nodes(func)
    calls = Enum.filter(all, &(&1.type == :call and &1.source_span != nil))

    detect_map_join_interpolation(calls) ++
      detect_map_join_concat(calls) ++
      detect_concat_around_join(all) ++
      detect_reduce_string_concat(calls, all)
  end

  # Enum.map(fn -> "...\#{x}..." end) |> Enum.join
  defp detect_map_join_interpolation(calls) do
    joins = Enum.filter(calls, &enum_call?(&1, :join))

    Enum.flat_map(joins, &map_join_interpolation_smell(&1, calls))
  end

  defp map_join_interpolation_smell(join, calls) do
    case find_piped_producer(join, calls) do
      %{meta: %{function: :map, module: Enum}} = map_call ->
        string_building_smell(
          callback_builds_strings?(map_call),
          "Enum.map(& \"...\#{}\") |> Enum.join: builds intermediate strings. Return iolists from map and pass to IO directly",
          join
        )

      _ ->
        []
    end
  end

  defp string_building_smell(false, _message, _node), do: []

  defp string_building_smell(true, message, node) do
    [
      Finding.new(
        kind: :string_building,
        message: message,
        location: Format.location(node)
      )
    ]
  end

  # Enum.map_join(items, fn -> "...\#{x}..." end)
  defp detect_map_join_concat(calls) do
    calls
    |> Enum.filter(&(enum_call?(&1, :map_join) and callback_builds_strings?(&1)))
    |> Enum.map(fn call ->
      Finding.new(
        kind: :string_building,
        message:
          "Enum.map_join with string interpolation: builds N intermediate strings. Use Enum.map/2 returning iolists",
        location: Format.location(call)
      )
    end)
  end

  # "<div>" <> Enum.join(parts) <> "</div>"
  defp detect_concat_around_join(all) do
    concat_ids_with_join =
      Enum.filter(all, fn node ->
        node.type == :binary_op and node.meta[:operator] == :<> and node.source_span != nil and
          Enum.any?(IR.all_nodes(node), &enum_call?(&1, :join))
      end)

    nested_ids =
      concat_ids_with_join
      |> Enum.flat_map(fn c -> Enum.map(c.children, & &1.id) end)
      |> MapSet.new()

    concat_ids_with_join
    |> Enum.reject(fn c -> c.id in nested_ids end)
    |> Enum.map(fn concat ->
      Finding.new(
        kind: :string_building,
        message:
          "String concatenation around Enum.join: wrap in a list instead — [\"<div>\", parts, \"</div>\"]",
        location: Format.location(concat)
      )
    end)
  end

  # Enum.reduce(items, "", fn item, acc -> acc <> "..." end)
  defp detect_reduce_string_concat(calls, all) do
    calls
    |> Enum.filter(fn reduce ->
      enum_call?(reduce, :reduce) and has_empty_string_acc?(reduce) and
        callback_uses_string_concat?(reduce, all)
    end)
    |> Enum.map(fn reduce ->
      Finding.new(
        kind: :string_building,
        message:
          "Enum.reduce building string with <>: O(n²) copying. Use iolists or Enum.map_join",
        location: Format.location(reduce)
      )
    end)
  end

  defp enum_call?(%{type: :call, meta: %{module: Enum, function: f}}, target), do: f == target
  defp enum_call?(_, _), do: false

  defp find_piped_producer(consumer, calls) do
    Enum.find(calls, fn candidate ->
      candidate.id in Enum.map(consumer.children, & &1.id)
    end)
  end

  defp callback_builds_strings?(call) do
    call.children
    |> Enum.filter(&(&1.type == :fn))
    |> Enum.any?(fn fn_node ->
      subtree = IR.all_nodes(fn_node)
      has_interpolation?(subtree) or has_concat?(subtree)
    end)
  end

  defp has_interpolation?(nodes) do
    Enum.any?(nodes, fn n ->
      n.type == :call and n.meta[:function] == :<<>> and n.meta[:kind] == :local
    end)
  end

  defp has_concat?(nodes) do
    Enum.any?(nodes, fn n ->
      n.type == :binary_op and n.meta[:operator] == :<>
    end)
  end

  defp has_empty_string_acc?(%{children: children}) do
    Enum.any?(children, fn
      %{type: :literal, meta: %{value: ""}} -> true
      _ -> false
    end)
  end

  defp callback_uses_string_concat?(reduce, _all) do
    reduce.children
    |> Enum.filter(&(&1.type == :fn))
    |> Enum.any?(fn fn_node ->
      subtree = IR.all_nodes(fn_node)
      has_concat?(subtree) or has_interpolation?(subtree)
    end)
  end

  defp run_checks(project),
    do: Enum.flat_map(Reach.CLI.Analyses.Smell.Registry.checks(), & &1.run(project))

  # --- Rendering ---

  defp render_text(findings) do
    IO.puts(Format.header("Cross-Function Smell Detection"))

    if findings == [] do
      IO.puts("No issues found.\n")
    else
      grouped = Enum.group_by(findings, & &1.kind)

      render_group(Map.get(grouped, :redundant_traversal, []), "Redundant traversals")
      render_group(Map.get(grouped, :suboptimal, []), "Suboptimal patterns")
      render_group(Map.get(grouped, :redundant_computation, []), "Redundant computations")
      render_group(Map.get(grouped, :eager_pattern, []), "Eager where lazy suffices")
      render_group(Map.get(grouped, :string_building, []), "String building (use iolists)")
      render_group(Map.get(grouped, :dual_key_access, []), "Loose map contracts")
      render_group(Map.get(grouped, :fixed_shape_map, []), "Repeated map shapes")

      IO.puts("#{length(findings)} finding(s)\n")
    end
  end

  defp render_group([], _title), do: nil

  defp render_group(findings, title) do
    IO.puts(Format.section(title))
    Enum.each(findings, &render_finding/1)
  end

  defp render_finding(%Finding{kind: :fixed_shape_map} = finding) do
    IO.puts("  #{finding.location}")

    summary =
      [
        Format.yellow("#{finding.occurrences}x"),
        Format.bright(Enum.join(finding.keys, ", ")),
        Format.faint("consider a struct or explicit contract")
      ]
      |> Enum.join("  ")

    IO.puts("    #{summary}")
    render_evidence(finding.evidence, finding.location)
  end

  defp render_finding(finding) do
    IO.puts("  #{finding.location}")
    IO.puts("    #{Format.yellow(finding.message)}")
  end

  defp render_evidence(evidence, primary_location) when is_list(evidence) do
    evidence
    |> Enum.reject(&(&1 == primary_location))
    |> Enum.take(4)
    |> case do
      [] ->
        :ok

      locations ->
        IO.puts("    #{Format.faint("also:")}")
        Enum.each(locations, &IO.puts("      #{&1}"))
    end
  end

  defp render_evidence(_evidence, _primary_location), do: :ok
end
