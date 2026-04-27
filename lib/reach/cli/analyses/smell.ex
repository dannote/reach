defmodule Reach.CLI.Analyses.Smell do
  @moduledoc """
  Finds cross-function performance anti-patterns using data flow analysis.

  Detects redundant traversals, duplicate computations, unused results,
  and suboptimal Enum operations — including patterns that span function
  boundaries.

      mix reach.smell
      mix reach.smell --format json
      mix reach.smell lib/my_app/

  ## Options

    * `--format` — output format: `text` (default), `json`, `oneline`

  """

  @switches [format: :string]
  @aliases [f: :format]

  alias Reach.CLI.Format
  alias Reach.CLI.Project
  alias Reach.Effects
  alias Reach.IR

  def run(args) do
    {opts, args, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)
    format = opts[:format] || "text"
    path = List.first(args)

    project = Project.load(quiet: opts[:format] == "json")

    findings = analyze(project)

    findings =
      if path,
        do: Enum.filter(findings, &String.contains?(to_string(&1.location), path)),
        else: findings

    case format do
      "json" ->
        Format.render(%{findings: findings}, "reach.smell",
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
    detect_pipeline_waste(project) ++
      detect_redundant_computation(project) ++
      detect_eager_patterns(project) ++
      detect_string_building(project)
  end

  defp detect_pipeline_waste(project) do
    nodes = Map.values(project.nodes)

    func_defs = Enum.filter(nodes, &(&1.type == :function_def))

    Enum.flat_map(func_defs, fn func ->
      calls =
        func
        |> IR.all_nodes()
        |> Enum.filter(fn n ->
          n.type == :call and n.meta[:module] in [Enum, Stream] and
            n.meta[:kind] != :fun_ref and
            n.meta[:function] != nil and
            n.source_span != nil
        end)
        |> Enum.sort_by(fn n -> {n.source_span[:start_line], n.source_span[:start_col] || 0} end)

      find_pipeline_patterns(calls)
    end)
  end

  defp find_pipeline_patterns(calls) do
    calls
    |> Enum.chunk_every(2, 1, [])
    |> Enum.flat_map(fn
      [first, second] ->
        check_pair(first, second)

      _ ->
        []
    end)
  end

  defp check_pair(first, second) do
    if data_connected?(first, second) do
      detect_pattern(first, second)
    else
      []
    end
  end

  defp detect_pattern(first, second) do
    pattern = classify_pair(first, second)
    if pattern, do: [smell_for_pattern(pattern, second)], else: []
  end

  defp classify_pair(first, second) do
    cond do
      reverse_pair?(first, second) -> :reverse_reverse
      filter_count?(first, second) -> :filter_count
      map_count?(first, second) -> :map_count
      map_map?(first, second) -> :map_map
      filter_filter?(first, second) -> :filter_filter
      true -> nil
    end
  end

  defp smell_for_pattern(:reverse_reverse, node) do
    %{
      kind: :redundant_traversal,
      message: "Enum.reverse → Enum.reverse is a no-op",
      location: Format.location(node)
    }
  end

  defp smell_for_pattern(:filter_count, node) do
    %{
      kind: :suboptimal,
      message: "Enum.filter → Enum.count: use Enum.count/2 instead",
      location: Format.location(node)
    }
  end

  defp smell_for_pattern(:map_count, node) do
    %{
      kind: :suboptimal,
      message: "Enum.map → Enum.count: use Enum.count/2 with transform",
      location: Format.location(node)
    }
  end

  defp smell_for_pattern(:map_map, node) do
    %{
      kind: :suboptimal,
      message: "Enum.map → Enum.map: consider fusing into one pass",
      location: Format.location(node)
    }
  end

  defp smell_for_pattern(:filter_filter, node) do
    %{
      kind: :suboptimal,
      message: "Enum.filter → Enum.filter: combine predicates into one pass",
      location: Format.location(node)
    }
  end

  defp data_connected?(first, second) do
    # Check structural connection: in a pipe like `a |> b`, `a` becomes
    # the first child of `b` (via desugaring). For nested calls like
    # `b(a(...))`, `a` is also a child. We check if the first call is
    # a direct or near-direct child of the second.
    first.id in Enum.map(second.children, & &1.id) or
      Enum.any?(second.children, fn child ->
        first.id in Enum.map(child.children, & &1.id)
      end)
  rescue
    _ -> false
  end

  defp reverse_pair?(a, b) do
    a.meta[:function] == :reverse and b.meta[:function] == :reverse and
      a.meta[:arity] == 1 and b.meta[:arity] == 1
  end

  defp filter_count?(a, b) do
    a.meta[:function] == :filter and b.meta[:function] == :count
  end

  defp map_count?(a, b) do
    a.meta[:function] == :map and b.meta[:function] == :count
  end

  defp map_map?(a, b) do
    a.meta[:function] == :map and b.meta[:function] == :map and
      a.meta[:module] == b.meta[:module] and
      callbacks_pure?(a) and callbacks_pure?(b)
  end

  defp callbacks_pure?(call) do
    call.children
    |> Enum.filter(&(&1.type in [:fn, :call]))
    |> Enum.all?(fn child ->
      child
      |> Reach.IR.all_nodes()
      |> Enum.filter(&(&1.type == :call))
      |> Enum.all?(&Reach.Effects.pure?/1)
    end)
  end

  defp filter_filter?(a, b) do
    a.meta[:function] == :filter and b.meta[:function] == :filter
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

  @pattern_operators [:|, :{}]

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
        %{
          kind: :redundant_computation,
          message:
            "#{call_name(a)} called twice with same args (line #{a.source_span[:start_line]} and #{b.source_span[:start_line]})",
          location: Format.location(b)
        }
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

  # --- Eager patterns: Enum.map |> List.first, Enum.sort |> Enum.take ---

  defp detect_eager_patterns(project) do
    nodes = Map.values(project.nodes)
    func_defs = Enum.filter(nodes, &(&1.type == :function_def))

    Enum.flat_map(func_defs, fn func ->
      func
      |> IR.all_nodes()
      |> Enum.filter(&eager_call?/1)
      |> Enum.sort_by(fn n -> {n.source_span[:start_line], n.source_span[:start_col] || 0} end)
      |> Enum.chunk_every(2, 1, [])
      |> Enum.flat_map(&eager_pattern_for_pair/1)
    end)
  end

  defp eager_call?(n) do
    n.type == :call and n.meta[:module] in [Enum, List] and n.source_span != nil
  end

  defp eager_pattern_for_pair([first, second]) do
    case {first.meta[:function], second.meta[:function]} do
      {:map, :first} ->
        if data_connected?(first, second), do: [map_first_smell(second)], else: []

      {:sort, :take} ->
        if data_connected?(first, second), do: [sort_take_smell(second)], else: []

      _ ->
        []
    end
  end

  defp eager_pattern_for_pair(_), do: []

  defp map_first_smell(second) do
    %{
      kind: :eager_pattern,
      message: "Enum.map → List.first: builds entire list for one element. Use Enum.find_value/2",
      location: Format.location(second)
    }
  end

  defp sort_take_smell(second) do
    %{
      kind: :eager_pattern,
      message:
        "Enum.sort → Enum.take(#{take_count(second)}): sorts entire list. Consider partial sort",
      location: Format.location(second)
    }
  end

  defp take_count(node) do
    case node.children do
      [_, %{type: :literal, meta: %{value: n}}] -> n
      _ -> "?"
    end
  end

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
      %{
        kind: :string_building,
        message: message,
        location: Format.location(node)
      }
    ]
  end

  # Enum.map_join(items, fn -> "...\#{x}..." end)
  defp detect_map_join_concat(calls) do
    calls
    |> Enum.filter(&(enum_call?(&1, :map_join) and callback_builds_strings?(&1)))
    |> Enum.map(fn call ->
      %{
        kind: :string_building,
        message:
          "Enum.map_join with string interpolation: builds N intermediate strings. Use Enum.map/2 returning iolists",
        location: Format.location(call)
      }
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
      %{
        kind: :string_building,
        message:
          "String concatenation around Enum.join: wrap in a list instead — [\"<div>\", parts, \"</div>\"]",
        location: Format.location(concat)
      }
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
      %{
        kind: :string_building,
        message:
          "Enum.reduce building string with <>: O(n²) copying. Use iolists or Enum.map_join",
        location: Format.location(reduce)
      }
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

      IO.puts("#{length(findings)} finding(s)\n")
    end
  end

  defp render_group([], _title), do: nil

  defp render_group(findings, title) do
    IO.puts(Format.section(title))

    Enum.each(findings, fn f ->
      IO.puts("  #{f.location}")
      IO.puts("    #{Format.yellow(f.message)}")
    end)
  end
end
