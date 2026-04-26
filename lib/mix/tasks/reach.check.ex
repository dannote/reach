defmodule Mix.Tasks.Reach.Check do
  @moduledoc """
  Runs structural validation and change-safety checks.

      mix reach.check
      mix reach.check --arch
      mix reach.check --changed --base main
      mix reach.check --dead-code
      mix reach.check --smells
      mix reach.check --candidates

  ## Options

    * `--format` — output format: `text` or `json`
    * `--arch` — check `.reach.exs` architecture policy
    * `--changed` — report changed files and configured test hints
    * `--base` — git base ref for `--changed` (default: `main`)
    * `--dead-code` — find unused pure expressions
    * `--smells` — find graph/effect/data-flow performance smells
    * `--candidates` — emit advisory refactoring candidate placeholder

  """

  use Mix.Task

  alias Reach.CLI.TaskRunner

  @shortdoc "Structural validation and change-safety checks"

  @switches [
    format: :string,
    arch: :boolean,
    changed: :boolean,
    base: :string,
    dead_code: :boolean,
    smells: :boolean,
    candidates: :boolean,
    path: :string
  ]

  @aliases [f: :format]

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    cond do
      opts[:arch] -> run_arch(opts)
      opts[:changed] -> run_changed(opts)
      opts[:dead_code] -> TaskRunner.run("reach.dead_code", delegated_args(opts, positional))
      opts[:smells] -> TaskRunner.run("reach.smell", delegated_args(opts, positional))
      opts[:candidates] -> render_candidates_placeholder(opts)
      true -> run_default(opts)
    end
  end

  defp run_default(opts) do
    if File.exists?(".reach.exs") do
      run_arch(opts)
    else
      IO.puts("No default Reach checks configured.")
      IO.puts("Use --arch, --changed, --dead-code, --smells, or --candidates.")
    end
  end

  defp run_arch(opts) do
    config = load_config()
    project = Reach.CLI.Project.load()
    violations = dependency_violations(project, config)

    result = %{
      config: ".reach.exs",
      violations: violations,
      status: if(violations == [], do: "ok", else: "failed")
    }

    render_result(result, opts[:format], &render_arch_text/1)

    if violations != [] do
      System.halt(1)
    end
  end

  defp load_config do
    unless File.exists?(".reach.exs") do
      Mix.raise("No .reach.exs architecture policy found")
    end

    {config, _binding} = Code.eval_file(".reach.exs")
    config
  end

  defp dependency_violations(project, config) do
    layers = Keyword.get(config, :layers, [])
    forbidden = Keyword.get(config, :forbidden_deps, [])
    module_by_file = module_by_file(project)

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
           true <- {caller_layer, callee_layer} in forbidden do
        [
          %{
            type: "forbidden_dependency",
            caller_module: inspect(caller),
            caller_layer: caller_layer,
            callee_module: inspect(callee),
            callee_layer: callee_layer,
            file: node.source_span.file,
            line: node.source_span.start_line,
            call: "#{inspect(callee)}.#{node.meta[:function]}/#{node.meta[:arity]}"
          }
        ]
      else
        _ -> []
      end
    end)
  end

  defp remote_call?(node) do
    node.type == :call and node.meta[:kind] == :remote and node.meta[:module] != nil
  end

  defp module_by_file(project) do
    project.nodes
    |> Map.values()
    |> Enum.filter(&(&1.type == :module_def and &1.source_span))
    |> Map.new(fn node -> {node.source_span.file, node.meta[:name]} end)
  end

  defp module_layer(module, layers) do
    Enum.find_value(layers, fn {layer, patterns} ->
      if module_matches_any?(module, List.wrap(patterns)), do: layer
    end)
  end

  defp module_matches_any?(module, patterns) do
    name = inspect(module)
    Enum.any?(patterns, &glob_match?(name, to_string(&1)))
  end

  defp glob_match?(name, pattern) do
    pattern_regex =
      pattern
      |> Regex.escape()
      |> String.replace("\\*", ".*")

    Regex.match?(~r/^#{pattern_regex}$/, name)
  end

  defp run_changed(opts) do
    base = opts[:base] || "main"
    config = if File.exists?(".reach.exs"), do: load_config(), else: []
    files = changed_files(base)
    tests = suggested_tests(files, Keyword.get(config, :test_hints, []))

    result = %{
      base: base,
      changed_files: files,
      suggested_tests: tests,
      note: "Changed-function impact analysis is planned for a later phase."
    }

    render_result(result, opts[:format], &render_changed_text/1)
  end

  defp changed_files(base) do
    case System.cmd("git", ["diff", "--name-only", base <> "...HEAD"], stderr_to_stdout: true) do
      {output, 0} -> output |> String.split("\n", trim: true) |> Enum.reject(&(&1 == ""))
      {output, _} -> Mix.raise("Could not read changed files against #{base}: #{output}")
    end
  end

  defp suggested_tests(files, hints) do
    hints
    |> Enum.flat_map(fn {pattern, tests} ->
      if Enum.any?(files, &path_matches?(&1, pattern)), do: tests, else: []
    end)
    |> Enum.uniq()
  end

  defp path_matches?(path, pattern) do
    glob_match?(path, pattern)
  end

  defp render_candidates_placeholder(opts) do
    result = %{
      candidates: [],
      note: "Graph-backed project-wide refactoring candidates are planned for a later phase."
    }

    render_result(result, opts[:format], fn _ ->
      IO.puts("No automatic refactoring candidates are emitted yet.")

      IO.puts(
        "Planned candidate kinds: extract pure region, isolate effects, break cycles, move across layers, introduce boundary."
      )
    end)
  end

  defp delegated_args(opts, positional) do
    []
    |> maybe_put("--format", opts[:format])
    |> maybe_put("--path", opts[:path])
    |> Kernel.++(positional)
  end

  defp maybe_put(args, _flag, nil), do: args
  defp maybe_put(args, flag, value), do: args ++ [flag, to_string(value)]

  defp render_result(result, "json", _text_fun) do
    ensure_json_encoder!()
    IO.puts(Jason.encode!(result, pretty: true))
  end

  defp render_result(result, _format, text_fun), do: text_fun.(result)

  defp render_arch_text(%{violations: []}) do
    IO.puts("Architecture policy: OK")
  end

  defp render_arch_text(%{violations: violations}) do
    IO.puts("Architecture policy: #{length(violations)} violation(s)")

    Enum.each(violations, fn violation ->
      IO.puts(
        "  #{violation.file}:#{violation.line} #{violation.caller_layer} -> #{violation.callee_layer} " <>
          "#{violation.call}"
      )
    end)
  end

  defp render_changed_text(result) do
    IO.puts("Changed files against #{result.base}:")

    Enum.each(result.changed_files, fn file ->
      IO.puts("  #{file}")
    end)

    if result.suggested_tests != [] do
      IO.puts("\nSuggested tests:")
      Enum.each(result.suggested_tests, &IO.puts("  mix test #{&1}"))
    end

    IO.puts("\n#{result.note}")
  end

  defp ensure_json_encoder! do
    unless Code.ensure_loaded?(Jason) do
      Mix.raise("Jason is required for JSON output. Add {:jason, \"~> 1.0\"} to your deps.")
    end
  end
end
