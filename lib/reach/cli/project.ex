defmodule Reach.CLI.Project do
  @moduledoc false

  alias Reach.CLI.Format

  @display_root_key {__MODULE__, :display_root}

  def display_root, do: Process.get(@display_root_key)

  def load(opts \\ []) do
    quiet? = Keyword.get(opts, :quiet, false)
    compile(quiet?)

    project =
      case Keyword.get(opts, :paths) do
        nil ->
          set_display_root(File.cwd!())
          unless quiet?, do: Mix.shell().info("Analyzing project...")
          Reach.Project.from_mix_project()

        paths ->
          set_display_root(display_root_for_paths(paths))
          paths = expand_paths(paths)
          unless quiet?, do: Mix.shell().info("Analyzing #{length(paths)} file(s)...")
          Reach.Project.from_sources(paths)
      end

    Process.delete({__MODULE__, :func_index})
    project
  end

  defp set_display_root(root), do: Process.put(@display_root_key, Path.expand(root))

  defp display_root_for_paths(paths) do
    paths
    |> List.wrap()
    |> Enum.map(&root_candidate/1)
    |> common_path()
  end

  defp root_candidate(path) do
    expanded = Path.expand(path)

    cond do
      String.contains?(path, "*") ->
        path |> Path.dirname() |> Path.expand()

      File.dir?(expanded) and Path.basename(expanded) in ["lib", "src"] ->
        Path.dirname(expanded)

      File.dir?(expanded) ->
        expanded

      true ->
        expanded |> Path.dirname() |> source_root_from_file()
    end
  end

  defp source_root_from_file(dir) do
    if Path.basename(dir) in ["lib", "src"], do: Path.dirname(dir), else: dir
  end

  defp common_path([]), do: File.cwd!()
  defp common_path([path]), do: path

  defp common_path(paths) do
    split_paths = Enum.map(paths, &Path.split/1)
    min_length = split_paths |> Enum.map(&length/1) |> Enum.min()

    common_parts =
      0..(min_length - 1)
      |> Enum.reduce_while([], fn index, acc ->
        parts = Enum.map(split_paths, &Enum.at(&1, index))

        if Enum.uniq(parts) |> length() == 1,
          do: {:cont, [List.first(parts) | acc]},
          else: {:halt, acc}
      end)
      |> Enum.reverse()

    case common_parts do
      [] -> File.cwd!()
      parts -> Path.join(parts)
    end
  end

  defp expand_paths(paths) do
    paths
    |> List.wrap()
    |> Enum.flat_map(fn path ->
      cond do
        File.dir?(path) ->
          [Path.join(path, "**/*.ex"), Path.join(path, "**/*.erl")]
          |> Enum.flat_map(&Path.wildcard/1)

        String.contains?(path, "*") ->
          Path.wildcard(path)

        true ->
          [path]
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp compile(true) do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Quiet)

    try do
      Mix.Task.run("compile", ["--no-warnings-as-errors"])
    after
      Mix.shell(shell)
    end
  end

  defp compile(false), do: Mix.Task.run("compile", ["--no-warnings-as-errors"])

  def function_index(project) do
    case Process.get({__MODULE__, :func_index}) do
      nil ->
        index = build_function_index(project)
        Process.put({__MODULE__, :func_index}, index)
        index

      index ->
        index
    end
  end

  defp build_function_index(project) do
    func_defs =
      project.nodes
      |> Map.values()
      |> Enum.filter(fn n -> n.type == :function_def end)

    by_name_arity =
      Enum.group_by(func_defs, fn n -> {n.meta[:name], n.meta[:arity]} end)

    by_module =
      Enum.group_by(func_defs, fn n -> {n.meta[:module], n.meta[:name], n.meta[:arity]} end)

    by_file =
      func_defs
      |> Enum.filter(fn n -> n.source_span != nil end)
      |> Enum.group_by(fn n -> n.source_span[:file] end)
      |> Map.new(fn {file, fns} ->
        {file, Enum.sort_by(fns, fn n -> n.source_span[:start_line] end)}
      end)

    %{by_name_arity: by_name_arity, by_module: by_module, by_file: by_file, all: func_defs}
  end

  def find_function(project, target) do
    index = function_index(project)

    case target do
      {mod, fun, arity} ->
        find_function_node(index, mod, fun, arity)

      fun_string when is_binary(fun_string) ->
        Enum.find(index.all, fn node ->
          Format.func_id_to_string({node.meta[:module], node.meta[:name], node.meta[:arity]}) =~
            fun_string
        end)

      _ ->
        nil
    end
  end

  defp find_function_node(index, nil, fun, arity) do
    find_by_module(index, nil, fun, arity) ||
      find_sole_candidate(index, fun, arity)
  end

  defp find_function_node(index, mod, fun, arity) do
    find_by_module(index, mod, fun, arity) ||
      disambiguate_by_file(index, mod, fun, arity)
  end

  defp find_sole_candidate(index, fun, arity) do
    case Map.get(index.by_module, {nil, fun, arity}) do
      [single] -> single
      _ -> nil
    end
  end

  defp find_by_module(index, mod, fun, arity) do
    case Map.get(index.by_module, {mod, fun, arity}) do
      [first | _] -> first
      _ -> nil
    end
  end

  defp disambiguate_by_file(index, mod, fun, arity) when is_atom(mod) and mod != nil do
    path_hint =
      mod
      |> Atom.to_string()
      |> String.replace_leading("Elixir.", "")
      |> String.split(".")
      |> Enum.map_join("/", &Macro.underscore/1)

    find_in_file(index, fun, arity, path_hint) ||
      find_in_file_with_defaults(index, fun, arity, path_hint)
  end

  defp disambiguate_by_file(_index, _mod, _fun, _arity), do: nil

  defp find_in_file(index, fun, arity, path_hint) do
    candidates = Map.get(index.by_name_arity, {fun, arity}, [])

    Enum.find(candidates, fn n ->
      n.source_span != nil and String.ends_with?(n.source_span[:file], path_hint <> ".ex")
    end) ||
      Enum.find(candidates, fn n ->
        n.source_span != nil and String.contains?(n.source_span[:file], path_hint <> ".ex")
      end)
  end

  defp find_in_file_with_defaults(index, fun, arity, path_hint) do
    higher_arities =
      index.by_name_arity
      |> Enum.filter(fn {{f, a}, _} -> f == fun and a > arity end)
      |> Enum.flat_map(fn {_, nodes} -> nodes end)

    candidates =
      Enum.filter(higher_arities, fn n ->
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
    index = function_index(project)

    # Try exact file match first (fast path via by_file index)
    exact_fns = Map.get(index.by_file, file, [])

    result =
      exact_fns
      |> Enum.filter(fn n -> n.source_span.start_line <= line end)
      |> Enum.max_by(& &1.source_span.start_line, fn -> nil end)

    if result do
      result
    else
      # Fallback: fuzzy file match
      index.all
      |> Enum.filter(fn n ->
        n.source_span != nil and
          file_matches?(n.source_span.file, file) and
          n.source_span.start_line <= line
      end)
      |> Enum.max_by(& &1.source_span.start_line, fn -> nil end)
    end
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
    case parse_function_reference(name) do
      {mod_str, fun_str, arity} ->
        resolve_in_call_graph(project.call_graph, mod_str, fun_str, arity)

      nil ->
        resolve_unqualified_function_reference(project, name) ||
          resolve_by_function_name(project, name)
    end
  end

  defp resolve_unqualified_function_reference(project, name) do
    with [fun_str, arity_str] <- String.split(name, "/", parts: 2),
         {arity, ""} <- Integer.parse(arity_str),
         fun <- String.to_existing_atom(fun_str),
         [node | _] <- Map.get(function_index(project).by_name_arity, {fun, arity}, []) do
      {node.meta[:module], node.meta[:name], node.meta[:arity]}
    else
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp resolve_in_call_graph(cg, mod_str, fun_str, arity) do
    fun = String.to_existing_atom(fun_str)

    fuzzy_match_module(cg, mod_str, fun, arity)
  rescue
    ArgumentError -> nil
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

  defp resolve_by_function_name(project, name) do
    index = function_index(project)
    fun_atom = String.to_existing_atom(name)

    node =
      Enum.find(index.all, fn n ->
        n.meta[:name] == fun_atom
      end)

    if node do
      {node.meta[:module], node.meta[:name], node.meta[:arity]}
    else
      nil
    end
  rescue
    ArgumentError -> nil
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

        {Enum.reverse(callers, found), Enum.reduce(callers, vis, &MapSet.put(&2, &1))}
      end)

    acc = Enum.reduce(new_callers, acc, fn caller, acc -> [%{id: caller} | acc] end)

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
