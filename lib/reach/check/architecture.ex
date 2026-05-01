defmodule Reach.Check.Architecture do
  @moduledoc false

  alias Reach.Effects
  alias Reach.IR

  @known_config_keys [
    :layers,
    :forbidden_deps,
    :allowed_effects,
    :public_api,
    :internal,
    :internal_callers,
    :test_hints
  ]

  def run(project, config) do
    config_errors = config_violations(config)

    violations =
      if config_errors != [] do
        config_errors
      else
        violations(project, config)
      end

    %{
      config: ".reach.exs",
      status: if(violations == [], do: "ok", else: "failed"),
      violations: violations
    }
  end

  def violations(project, config) do
    graph = layer_graph(project, config)

    dependency_violations(project, config, graph) ++
      public_boundary_violations(project, config) ++
      layer_cycle_violations(graph) ++
      effect_policy_violations(project, config)
  end

  def config_violations(config) do
    unknown_key_violations(config) ++ config_shape_violations(config)
  end

  def layer_graph(project, config) do
    layers = Keyword.get(config, :layers, [])
    module_by_file = module_by_file(project)

    edges =
      project.nodes
      |> Map.values()
      |> Enum.filter(&remote_call?/1)
      |> Enum.flat_map(fn node ->
        caller_module = node.source_span && Map.get(module_by_file, node.source_span.file)
        callee_module = node.meta[:module]

        with caller when not is_nil(caller) <- caller_module,
             callee when not is_nil(callee) <- callee_module,
             caller_layer when not is_nil(caller_layer) <- module_layer(caller, layers),
             callee_layer when not is_nil(callee_layer) <- module_layer(callee, layers),
             true <- caller_layer != callee_layer do
          [%{from: caller_layer, to: callee_layer, node: node, caller: caller, callee: callee}]
        else
          _ -> []
        end
      end)

    %{edges: edges, adjacency: adjacency(edges)}
  end

  def dependency_violations(_project, config, layer_graph) do
    forbidden = Keyword.get(config, :forbidden_deps, [])

    layer_graph.edges
    |> Enum.filter(&({&1.from, &1.to} in forbidden))
    |> Enum.map(fn edge ->
      %{
        type: "forbidden_dependency",
        caller_module: inspect(edge.caller),
        caller_layer: edge.from,
        callee_module: inspect(edge.callee),
        callee_layer: edge.to,
        file: edge.node.source_span.file,
        line: edge.node.source_span.start_line,
        call: "#{inspect(edge.callee)}.#{edge.node.meta[:function]}/#{edge.node.meta[:arity]}"
      }
    end)
  end

  def module_by_file(project) do
    project.nodes
    |> Map.values()
    |> Enum.filter(&(&1.type == :module_def and &1.source_span))
    |> Map.new(fn node -> {node.source_span.file, node.meta[:name]} end)
  end

  def module_matches_any?(module, patterns) do
    name = inspect(module)
    Enum.any?(patterns, &glob_match?(name, to_string(&1)))
  end

  def glob_match?(value, pattern) do
    pattern_regex =
      pattern
      |> Regex.escape()
      |> String.replace("\\*\\*", ".*")
      |> String.replace("\\*", "[^/]*")

    Regex.match?(~r/^#{pattern_regex}$/, value)
  end

  def function_effects(func) do
    func
    |> IR.all_nodes()
    |> Enum.map(&Effects.classify/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def concrete_effects(func), do: function_effects(func) -- [:pure, :unknown, :exception]

  defp unknown_key_violations(config) do
    config
    |> Keyword.keys()
    |> Enum.reject(&(&1 in @known_config_keys))
    |> Enum.map(fn key ->
      %{
        type: "config_error",
        key: to_string(key),
        message: "Unknown .reach.exs key #{inspect(key)}"
      }
    end)
  end

  defp config_shape_violations(config) do
    []
    |> config_check(config, :layers, &valid_layers?/1, "expected keyword list of layer: patterns")
    |> config_check(
      config,
      :forbidden_deps,
      &valid_forbidden_deps?/1,
      "expected list of {from_layer, to_layer}"
    )
    |> config_check(
      config,
      :allowed_effects,
      &valid_allowed_effects?/1,
      "expected list of {module_pattern, effects}"
    )
    |> config_check(
      config,
      :public_api,
      &valid_pattern_list?/1,
      "expected string or list of module patterns"
    )
    |> config_check(
      config,
      :internal,
      &valid_pattern_list?/1,
      "expected string or list of module patterns"
    )
    |> config_check(
      config,
      :internal_callers,
      &valid_internal_callers?/1,
      "expected list of {internal_pattern, caller_patterns}"
    )
    |> config_check(
      config,
      :test_hints,
      &valid_test_hints?/1,
      "expected list of {path_glob, test_paths}"
    )
  end

  defp config_check(violations, config, key, validator, message) do
    if Keyword.has_key?(config, key) and not validator.(Keyword.get(config, key)) do
      [%{type: "config_error", key: to_string(key), message: message} | violations]
    else
      violations
    end
  end

  defp valid_layers?(value) when is_list(value) do
    Enum.all?(value, fn
      {layer, patterns} when is_atom(layer) -> valid_pattern_list?(patterns)
      _ -> false
    end)
  end

  defp valid_layers?(_value), do: false

  defp valid_forbidden_deps?(value) when is_list(value) do
    Enum.all?(value, fn
      {from, to} when is_atom(from) and is_atom(to) -> true
      _ -> false
    end)
  end

  defp valid_forbidden_deps?(_value), do: false

  defp valid_allowed_effects?(value) when is_list(value) do
    Enum.all?(value, fn
      {pattern, effects} when is_binary(pattern) and is_list(effects) ->
        Enum.all?(effects, &is_atom/1)

      _ ->
        false
    end)
  end

  defp valid_allowed_effects?(_value), do: false

  defp valid_pattern_list?(value) when is_binary(value), do: true
  defp valid_pattern_list?(value) when is_list(value), do: Enum.all?(value, &is_binary/1)
  defp valid_pattern_list?(_value), do: false

  defp valid_internal_callers?(value) when is_list(value) do
    Enum.all?(value, fn
      {internal_pattern, caller_patterns} when is_binary(internal_pattern) ->
        valid_pattern_list?(caller_patterns)

      _ ->
        false
    end)
  end

  defp valid_internal_callers?(_value), do: false

  defp valid_test_hints?(value) when is_list(value) do
    Enum.all?(value, fn
      {pattern, tests} when is_binary(pattern) and is_list(tests) ->
        Enum.all?(tests, &is_binary/1)

      _ ->
        false
    end)
  end

  defp valid_test_hints?(_value), do: false

  defp adjacency(edges) do
    Enum.reduce(edges, %{}, fn edge, acc ->
      Map.update(acc, edge.from, MapSet.new([edge.to]), &MapSet.put(&1, edge.to))
    end)
  end

  defp public_boundary_violations(project, config) do
    public_api = Keyword.get(config, :public_api, []) |> List.wrap()
    internal = Keyword.get(config, :internal, []) |> List.wrap()
    internal_callers = Keyword.get(config, :internal_callers, [])
    module_by_file = module_by_file(project)

    project.nodes
    |> Map.values()
    |> Enum.filter(&remote_call?/1)
    |> Enum.flat_map(fn node ->
      caller = node.source_span && Map.get(module_by_file, node.source_span.file)
      callee = node.meta[:module]

      cond do
        caller == nil or callee == nil ->
          []

        public_api != [] and top_level_api_call?(caller, callee, public_api, internal) ->
          [
            %{
              type: "public_api_boundary",
              caller_module: inspect(caller),
              callee_module: inspect(callee),
              file: node.source_span.file,
              line: node.source_span.start_line,
              call: "#{inspect(callee)}.#{node.meta[:function]}/#{node.meta[:arity]}",
              rule: "calls into non-public API module"
            }
          ]

        internal != [] and internal_call_violation?(caller, callee, internal, internal_callers) ->
          [
            %{
              type: "internal_boundary",
              caller_module: inspect(caller),
              callee_module: inspect(callee),
              file: node.source_span.file,
              line: node.source_span.start_line,
              call: "#{inspect(callee)}.#{node.meta[:function]}/#{node.meta[:arity]}",
              rule: "caller is not allowed to call configured internal module"
            }
          ]

        true ->
          []
      end
    end)
  end

  defp top_level_api_call?(caller, callee, public_api, internal) do
    public_api
    |> Enum.map(&public_api_namespace/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.any?(fn namespace ->
      module_under_namespace?(callee, namespace) and
        not module_under_namespace?(caller, namespace) and
        not module_matches_any?(callee, public_api) and
        not module_matches_any?(callee, internal)
    end)
  end

  defp internal_call_violation?(caller, callee, internal, internal_callers) do
    module_matches_any?(callee, internal) and
      not allowed_internal_caller?(caller, callee, internal_callers)
  end

  defp allowed_internal_caller?(caller, callee, internal_callers) do
    matching_rule =
      Enum.find(internal_callers, fn {internal_pattern, _caller_patterns} ->
        module_matches_any?(callee, [internal_pattern])
      end)

    case matching_rule do
      {_internal_pattern, caller_patterns} ->
        module_matches_any?(caller, List.wrap(caller_patterns))

      nil ->
        module_namespace(caller) == module_namespace(callee)
    end
  end

  defp public_api_namespace(pattern) do
    pattern
    |> to_string()
    |> String.replace_suffix(".*", "")
    |> String.trim_trailing("*")
    |> String.trim_trailing(".")
    |> case do
      "" -> nil
      namespace -> namespace
    end
  end

  defp module_under_namespace?(module, namespace) do
    name = module_name(module)
    name == namespace or String.starts_with?(name, namespace <> ".")
  end

  defp module_namespace(module) do
    module
    |> module_name()
    |> String.split(".")
    |> List.first()
  end

  defp module_name(module) do
    module
    |> Atom.to_string()
    |> String.replace_leading("Elixir.", "")
  end

  defp layer_cycle_violations(%{adjacency: adjacency}) do
    adjacency
    |> Map.keys()
    |> Enum.flat_map(&walk_layer_cycle(adjacency, &1, &1, []))
    |> Enum.map(&canonical_cycle/1)
    |> Enum.uniq()
    |> Enum.map(fn cycle -> %{type: "layer_cycle", layers: cycle} end)
  end

  defp walk_layer_cycle(_adjacency, start, current, path) when length(path) > 8 do
    if current == start and path != [], do: [Enum.reverse(path)], else: []
  end

  defp walk_layer_cycle(adjacency, start, current, path) do
    adjacency
    |> Map.get(current, MapSet.new())
    |> Enum.flat_map(fn next ->
      cond do
        next == start and path != [] -> [Enum.reverse([current | path])]
        next in path -> []
        true -> walk_layer_cycle(adjacency, start, next, [current | path])
      end
    end)
  end

  defp canonical_cycle(cycle) do
    cycle
    |> Enum.map(&to_string/1)
    |> Enum.sort()
  end

  defp effect_policy_violations(project, config) do
    policies = Keyword.get(config, :allowed_effects, [])
    module_by_file = module_by_file(project)

    project.nodes
    |> Map.values()
    |> Enum.filter(&(&1.type == :function_def))
    |> Enum.flat_map(&effect_policy_violation(&1, policies, module_by_file))
  end

  defp effect_policy_violation(func, policies, module_by_file) do
    module =
      func.meta[:module] || (func.source_span && Map.get(module_by_file, func.source_span.file))

    with allowed when not is_nil(allowed) <- allowed_effects_for(module, policies),
         effects <- function_effects(func),
         disallowed when disallowed != [] <- effects -- allowed do
      [
        %{
          type: "effect_policy",
          module: inspect(module),
          function: "#{func.meta[:name]}/#{func.meta[:arity]}",
          allowed_effects: Enum.map(allowed, &to_string/1),
          actual_effects: Enum.map(effects, &to_string/1),
          disallowed_effects: Enum.map(disallowed, &to_string/1),
          file: func.source_span && func.source_span.file,
          line: func.source_span && func.source_span.start_line
        }
      ]
    else
      _ -> []
    end
  end

  defp allowed_effects_for(module, policies) do
    Enum.find_value(policies, fn {pattern, effects} ->
      if module_matches_any?(module, [pattern]), do: effects
    end)
  end

  def remote_call?(node) do
    node.type == :call and node.meta[:kind] == :remote and is_atom(node.meta[:module]) and
      node.meta[:function] not in [:__aliases__, :{}]
  end

  defp module_layer(module, layers) do
    Enum.find_value(layers, fn {layer, patterns} ->
      if module_matches_any?(module, List.wrap(patterns)), do: layer
    end)
  end
end
