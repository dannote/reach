defmodule Reach.Check.Architecture.Config do
  @moduledoc false

  defmodule Deps do
    @moduledoc false
    defstruct forbidden: []
  end

  defmodule Calls do
    @moduledoc false
    defstruct forbidden: []
  end

  defmodule Effects do
    @moduledoc false
    defstruct allowed: []
  end

  defmodule Boundaries do
    @moduledoc false
    defstruct public: [], internal: [], internal_callers: []
  end

  defmodule Tests do
    @moduledoc false
    defstruct hints: []
  end

  defmodule Source do
    @moduledoc false
    defstruct forbidden_modules: [], forbidden_files: []
  end

  defmodule Error do
    @moduledoc false
    defstruct [:path, :message]

    def to_violation(%__MODULE__{path: path, message: message}) do
      key = path |> List.wrap() |> Enum.map_join(".", &to_string/1)

      %{
        type: "config_error",
        key: key,
        path: Enum.map(List.wrap(path), &to_string/1),
        message: message
      }
    end
  end

  defstruct layers: [],
            deps: nil,
            calls: nil,
            effects: nil,
            boundaries: nil,
            tests: nil,
            source: nil

  @top_level_keys [
    :layers,
    :deps,
    :calls,
    :effects,
    :boundaries,
    :tests,
    :source,
    :forbidden_deps,
    :allowed_effects,
    :forbidden_calls,
    :public_api,
    :internal,
    :internal_callers,
    :test_hints,
    :forbidden_modules,
    :forbidden_files
  ]

  def from_terms(%__MODULE__{} = config), do: {:ok, normalize(config)}

  def from_terms(config) when is_list(config) do
    errors = errors(config)

    if errors == [] do
      {:ok, normalize(config)}
    else
      {:error, errors}
    end
  end

  def from_terms(_config) do
    {:error, [%Error{path: [], message: "expected .reach.exs to evaluate to a keyword list"}]}
  end

  def normalize(%__MODULE__{} = config) do
    %__MODULE__{
      config
      | deps: config.deps || %Deps{},
        calls: config.calls || %Calls{},
        effects: config.effects || %Effects{},
        boundaries: config.boundaries || %Boundaries{},
        tests: config.tests || %Tests{},
        source: config.source || %Source{}
    }
  end

  def normalize(config) when is_list(config) do
    %__MODULE__{
      layers: Keyword.get(config, :layers, []),
      deps: %Deps{forbidden: nested(config, [:deps, :forbidden], :forbidden_deps, [])},
      calls: %Calls{forbidden: nested(config, [:calls, :forbidden], :forbidden_calls, [])},
      effects: %Effects{allowed: nested(config, [:effects, :allowed], :allowed_effects, [])},
      boundaries: %Boundaries{
        public: nested(config, [:boundaries, :public], :public_api, []),
        internal: nested(config, [:boundaries, :internal], :internal, []),
        internal_callers: nested(config, [:boundaries, :internal_callers], :internal_callers, [])
      },
      tests: %Tests{hints: nested(config, [:tests, :hints], :test_hints, [])},
      source: %Source{
        forbidden_modules: nested(config, [:source, :forbidden_modules], :forbidden_modules, []),
        forbidden_files: nested(config, [:source, :forbidden_files], :forbidden_files, [])
      }
    }
  end

  def errors(config) when is_list(config) do
    if Keyword.keyword?(config) do
      unknown_key_errors(config) ++ shape_errors(config)
    else
      [%Error{path: [], message: "expected keyword list"}]
    end
  end

  def errors(_config), do: [%Error{path: [], message: "expected keyword list"}]

  defp unknown_key_errors(config) do
    config
    |> Keyword.keys()
    |> Enum.reject(&(&1 in @top_level_keys))
    |> Enum.map(fn key ->
      %Error{path: [key], message: "Unknown .reach.exs key #{inspect(key)}"}
    end)
  end

  defp shape_errors(config) do
    []
    |> check(config, [:layers], &valid_layers?/1, "expected keyword list of layer: patterns")
    |> check(config, [:deps], &valid_group?/1, "expected keyword list")
    |> check(
      config,
      [:deps, :forbidden],
      &valid_forbidden_deps?/1,
      "expected list of {from_layer, to_layer}"
    )
    |> check(config, [:calls], &valid_group?/1, "expected keyword list")
    |> check(
      config,
      [:calls, :forbidden],
      &valid_forbidden_calls?/1,
      "expected list of {caller_patterns, call_patterns} or {caller_patterns, call_patterns, opts}"
    )
    |> check(config, [:effects], &valid_group?/1, "expected keyword list")
    |> check(
      config,
      [:effects, :allowed],
      &valid_allowed_effects?/1,
      "expected list of {module_pattern, effects}"
    )
    |> check(config, [:boundaries], &valid_group?/1, "expected keyword list")
    |> check(
      config,
      [:boundaries, :public],
      &valid_pattern_list?/1,
      "expected string or list of module patterns"
    )
    |> check(
      config,
      [:boundaries, :internal],
      &valid_pattern_list?/1,
      "expected string or list of module patterns"
    )
    |> check(
      config,
      [:boundaries, :internal_callers],
      &valid_internal_callers?/1,
      "expected list of {internal_pattern, caller_patterns}"
    )
    |> check(config, [:tests], &valid_group?/1, "expected keyword list")
    |> check(
      config,
      [:tests, :hints],
      &valid_test_hints?/1,
      "expected list of {path_glob, test_paths}"
    )
    |> check(config, [:source], &valid_group?/1, "expected keyword list")
    |> check(
      config,
      [:source, :forbidden_modules],
      &valid_pattern_list?/1,
      "expected string or list of module patterns"
    )
    |> check(
      config,
      [:source, :forbidden_files],
      &valid_pattern_list?/1,
      "expected string or list of path globs"
    )
    |> check(
      config,
      [:forbidden_deps],
      &valid_forbidden_deps?/1,
      "expected list of {from_layer, to_layer}"
    )
    |> check(
      config,
      [:allowed_effects],
      &valid_allowed_effects?/1,
      "expected list of {module_pattern, effects}"
    )
    |> check(
      config,
      [:forbidden_calls],
      &valid_forbidden_calls?/1,
      "expected list of {caller_patterns, call_patterns} or {caller_patterns, call_patterns, opts}"
    )
    |> check(
      config,
      [:public_api],
      &valid_pattern_list?/1,
      "expected string or list of module patterns"
    )
    |> check(
      config,
      [:internal],
      &valid_pattern_list?/1,
      "expected string or list of module patterns"
    )
    |> check(
      config,
      [:internal_callers],
      &valid_internal_callers?/1,
      "expected list of {internal_pattern, caller_patterns}"
    )
    |> check(
      config,
      [:test_hints],
      &valid_test_hints?/1,
      "expected list of {path_glob, test_paths}"
    )
    |> check(
      config,
      [:forbidden_modules],
      &valid_pattern_list?/1,
      "expected string or list of module patterns"
    )
    |> check(
      config,
      [:forbidden_files],
      &valid_pattern_list?/1,
      "expected string or list of path globs"
    )
    |> unknown_nested_key_errors(config, [:deps], [:forbidden])
    |> unknown_nested_key_errors(config, [:calls], [:forbidden])
    |> unknown_nested_key_errors(config, [:effects], [:allowed])
    |> unknown_nested_key_errors(config, [:boundaries], [:public, :internal, :internal_callers])
    |> unknown_nested_key_errors(config, [:tests], [:hints])
    |> unknown_nested_key_errors(config, [:source], [:forbidden_modules, :forbidden_files])
  end

  defp check(errors, config, path, validator, message) do
    case get_in_config(config, path) do
      :missing ->
        errors

      value ->
        if validator.(value), do: errors, else: [%Error{path: path, message: message} | errors]
    end
  end

  defp unknown_nested_key_errors(errors, config, path, allowed_keys) do
    case get_in_config(config, path) do
      value when is_list(value) -> nested_key_errors(value, path, allowed_keys) ++ errors
      _ -> errors
    end
  end

  defp nested_key_errors(value, path, allowed_keys) do
    if Keyword.keyword?(value) do
      value
      |> Keyword.keys()
      |> Enum.reject(&(&1 in allowed_keys))
      |> Enum.map(fn key ->
        %Error{path: path ++ [key], message: "Unknown .reach.exs key #{inspect(key)}"}
      end)
    else
      []
    end
  end

  defp nested(config, path, flat_key, default) do
    case get_in_config(config, path) do
      :missing -> Keyword.get(config, flat_key, default)
      value -> value
    end
  end

  defp get_in_config(config, [key]) do
    if Keyword.has_key?(config, key), do: Keyword.get(config, key), else: :missing
  end

  defp get_in_config(config, [key | rest]) do
    case get_in_config(config, [key]) do
      value when is_list(value) -> get_in_config(value, rest)
      :missing -> :missing
      _value -> :missing
    end
  end

  defp valid_group?(value), do: Keyword.keyword?(value)

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

  defp valid_forbidden_calls?(value) when is_list(value) do
    Enum.all?(value, fn
      {caller_patterns, call_patterns} ->
        valid_pattern_list?(caller_patterns) and valid_pattern_list?(call_patterns)

      {caller_patterns, call_patterns, opts} when is_list(opts) ->
        valid_pattern_list?(caller_patterns) and valid_pattern_list?(call_patterns) and
          valid_pattern_list?(Keyword.get(opts, :except, []))

      _ ->
        false
    end)
  end

  defp valid_forbidden_calls?(_value), do: false

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
end
