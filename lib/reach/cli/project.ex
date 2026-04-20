defmodule Reach.CLI.Project do
  @moduledoc false

  alias Reach.CLI.Format

  def load(opts \\ []) do
    Mix.Task.run("compile", ["--no-warnings-as-errors"])

    case Keyword.get(opts, :paths) do
      nil ->
        Mix.shell().info("Analyzing project...")
        Reach.Project.from_mix_project()

      paths ->
        Mix.shell().info("Analyzing #{length(paths)} file(s)...")
        Reach.Project.from_sources(paths)
    end
  end

  def find_function(project, target) do
    nodes = Map.values(project.nodes)

    case target do
      {mod, fun, arity} ->
        find_function_node(nodes, mod, fun, arity)

      fun_string when is_binary(fun_string) ->
        Enum.find(nodes, fn node ->
          node.type == :function_def and
            Format.func_id_to_string({node.meta[:module], node.meta[:name], node.meta[:arity]}) =~
              fun_string
        end)

      _ ->
        nil
    end
  end

  defp find_function_node(nodes, nil, fun, arity) do
    find_by_module(nodes, nil, fun, arity) ||
      find_sole_candidate(nodes, fun, arity)
  end

  defp find_function_node(nodes, mod, fun, arity) do
    find_by_module(nodes, mod, fun, arity) ||
      disambiguate_by_file(nodes, mod, fun, arity)
  end

  defp find_sole_candidate(nodes, fun, arity) do
    nodes
    |> Enum.filter(fn n ->
      n.type == :function_def and
        n.meta[:module] == nil and n.meta[:name] == fun and n.meta[:arity] == arity
    end)
    |> case do
      [single] -> single
      _ -> nil
    end
  end

  defp find_by_module(nodes, mod, fun, arity) do
    Enum.find(nodes, fn n ->
      n.type == :function_def and
        n.meta[:module] == mod and n.meta[:name] == fun and n.meta[:arity] == arity
    end)
  end

  defp disambiguate_by_file(nodes, mod, fun, arity) when is_atom(mod) and mod != nil do
    path_hint =
      mod
      |> Atom.to_string()
      |> String.replace_leading("Elixir.", "")
      |> String.split(".")
      |> Enum.map_join("/", &Macro.underscore/1)

    find_in_file(nodes, fun, arity, path_hint) ||
      find_in_file_with_defaults(nodes, fun, arity, path_hint)
  end

  defp disambiguate_by_file(_nodes, _mod, _fun, _arity), do: nil

  defp find_in_file(nodes, fun, arity, path_hint) do
    candidates =
      Enum.filter(nodes, fn n ->
        n.type == :function_def and n.meta[:name] == fun and n.meta[:arity] == arity and
          n.source_span != nil
      end)

    Enum.find(candidates, fn n ->
      String.ends_with?(n.source_span[:file], path_hint <> ".ex")
    end) ||
      Enum.find(candidates, fn n ->
        String.contains?(n.source_span[:file], path_hint <> ".ex")
      end)
  end

  defp find_in_file_with_defaults(nodes, fun, arity, path_hint) do
    candidates =
      Enum.filter(nodes, fn n ->
        n.type == :function_def and n.meta[:name] == fun and n.meta[:arity] > arity and
          n.source_span != nil and
          (String.ends_with?(n.source_span[:file], path_hint <> ".ex") or
             String.contains?(n.source_span[:file], path_hint <> ".ex"))
      end)

    Enum.min_by(candidates, fn n -> n.meta[:arity] end, fn -> nil end)
  end

  def resolve_target(project, raw) when is_binary(raw) do
    case parse_file_line(raw) do
      {file, line} ->
        node = find_function_at_location(project, file, line)

        if node do
          {node.meta[:module], node.meta[:name], node.meta[:arity]}
        else
          nil
        end

      nil ->
        resolve_function(project, raw)
    end
  end

  def parse_file_line(raw) do
    case raw |> String.reverse() |> String.split(":", parts: 2) do
      [rev_digits, rev_file] when rev_file != "" ->
        digits = String.reverse(rev_digits)
        file = String.reverse(rev_file)

        case Integer.parse(digits) do
          {line, ""} -> {file, line}
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def parse_function_reference(name) do
    with [qualified, arity_str] <- String.split(name, "/", parts: 2),
         {arity, ""} <- Integer.parse(arity_str),
         {mod_str, fun_str} <- split_module_function(qualified) do
      {mod_str, fun_str, arity}
    else
      _ -> nil
    end
  end

  defp split_module_function(qualified) do
    case qualified |> String.reverse() |> String.split(".", parts: 2) do
      [rev_fun, rev_mod] ->
        fun = String.reverse(rev_fun)
        mod = String.reverse(rev_mod)
        if fun != "" and mod != "", do: {mod, fun}

      _ ->
        nil
    end
  end

  def find_function_at_location(project, file, line) do
    project.nodes
    |> Map.values()
    |> Enum.filter(fn n ->
      n.type == :function_def and n.source_span != nil and
        file_matches?(n.source_span.file, file) and
        n.source_span.start_line <= line
    end)
    |> Enum.max_by(& &1.source_span.start_line, fn -> nil end)
  end

  def resolve_function(project, target) do
    case target do
      {mod, fun, arity} ->
        {mod, fun, arity}

      name when is_binary(name) ->
        resolve_function_by_name(project, name)

      _ ->
        nil
    end
  end

  defp resolve_function_by_name(project, name) do
    nodes = Map.values(project.nodes)
    cg = project.call_graph

    case parse_function_reference(name) do
      {mod_str, fun_str, arity} ->
        resolve_in_call_graph(cg, mod_str, fun_str, arity)

      nil ->
        resolve_by_function_name(nodes, name)
    end
  end

  defp resolve_in_call_graph(cg, mod_str, fun_str, arity) do
    mod = String.split(mod_str, ".") |> Enum.map(&String.to_atom/1) |> Module.concat()
    fun = String.to_atom(fun_str)

    (Graph.has_vertex?(cg, {mod, fun, arity}) && {mod, fun, arity}) ||
      fuzzy_match_module(cg, mod_str, fun, arity)
  end

  defp fuzzy_match_module(cg, mod_str, fun, arity) do
    downcased = String.downcase(mod_str)

    Graph.vertices(cg)
    |> Enum.find_value(fn
      {m, ^fun, ^arity} when is_atom(m) and m != nil ->
        actual = m |> Atom.to_string() |> String.replace_leading("Elixir.", "")

        if String.downcase(actual) == downcased do
          {m, fun, arity}
        end

      _ ->
        nil
    end)
  end

  defp resolve_by_function_name(nodes, name) do
    node =
      Enum.find(nodes, fn n ->
        n.type == :function_def and
          to_string(n.meta[:name]) == name
      end)

    if node do
      {node.meta[:module], node.meta[:name], node.meta[:arity]}
    else
      nil
    end
  end

  def callers(project, target, depth \\ 4) do
    cg = project.call_graph
    variants = all_variants(cg, target)
    do_find_callers(cg, variants, depth, MapSet.new(variants), [])
  end

  def callees(project, target, depth \\ 3) do
    cg = project.call_graph
    variants = all_variants(cg, target)
    visited = MapSet.new(variants)

    initial =
      variants
      |> Enum.flat_map(&Graph.out_neighbors(cg, &1))
      |> Enum.filter(&mfa?/1)
      |> Enum.uniq()

    Enum.map(initial, fn callee ->
      new_visited = MapSet.put(visited, callee)
      children = walk_callees(cg, callee, depth, 2, new_visited)
      %{id: callee, depth: 1, children: children}
    end)
  end

  def func_location(project, func_id) do
    project.nodes
    |> Map.values()
    |> Enum.find(fn n ->
      n.type == :function_def and
        {n.meta[:module], n.meta[:name], n.meta[:arity]} == func_id
    end)
    |> case do
      nil -> "unknown"
      node -> Format.location(node)
    end
  end

  def mfa?({m, f, a}) when is_atom(m) and is_atom(f) and is_number(a), do: true
  def mfa?(_), do: false

  def all_variants(cg, {nil, fun, arity}) do
    named_mod = find_named_module(cg, fun, arity)

    [{nil, fun, arity}, {named_mod, fun, arity}]
    |> Enum.uniq()
    |> Enum.filter(&Graph.has_vertex?(cg, &1))
  end

  def all_variants(cg, {mod, fun, arity}) do
    [{nil, fun, arity}, {mod, fun, arity}]
    |> Enum.uniq()
    |> Enum.filter(&Graph.has_vertex?(cg, &1))
  end

  defp find_named_module(cg, fun, arity) do
    Graph.vertices(cg)
    |> Enum.find_value(fn
      {m, ^fun, ^arity} when is_atom(m) and m != nil -> m
      _ -> nil
    end)
  end

  defp do_find_callers(_cg, [], _depth, _visited, acc), do: Enum.reverse(acc)
  defp do_find_callers(_cg, _frontier, 0, _visited, acc), do: Enum.reverse(acc)

  defp do_find_callers(cg, frontier, depth, visited, acc) do
    {new_callers, new_visited} =
      Enum.reduce(frontier, {[], visited}, fn f, {found, vis} ->
        callers =
          Graph.in_neighbors(cg, f)
          |> Enum.filter(&mfa?/1)
          |> Enum.reject(&MapSet.member?(vis, &1))

        {found ++ callers, Enum.reduce(callers, vis, &MapSet.put(&2, &1))}
      end)

    acc = acc ++ Enum.map(new_callers, &%{id: &1})

    if depth > 1,
      do: do_find_callers(cg, new_callers, depth - 1, new_visited, acc),
      else: Enum.reverse(acc)
  end

  defp walk_callees(_cg, _from, max_depth, current_depth, _visited)
       when current_depth > max_depth,
       do: []

  defp walk_callees(cg, from, max_depth, current_depth, visited) do
    neighbors = Graph.out_neighbors(cg, from) |> Enum.filter(&mfa?/1)

    Enum.flat_map(neighbors, fn callee ->
      expand_callee(cg, callee, max_depth, current_depth, visited)
    end)
  end

  defp expand_callee(cg, callee, max_depth, current_depth, visited) do
    if MapSet.member?(visited, callee) do
      []
    else
      new_visited = MapSet.put(visited, callee)
      children = walk_callees(cg, callee, max_depth, current_depth + 1, new_visited)
      [%{id: callee, depth: current_depth, children: children}]
    end
  end

  def file_matches?(_file, nil), do: true
  def file_matches?(nil, _path), do: false

  def file_matches?(file, path) do
    file == path or
      String.ends_with?(file, "/" <> path) or
      String.starts_with?(file, path)
  end
end
