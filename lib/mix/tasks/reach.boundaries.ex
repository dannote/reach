defmodule Mix.Tasks.Reach.Boundaries do
  @moduledoc """
  Functions with multiple distinct side effects — reads, writes, IO,
  and message sends in the same function body.

  A function with a single effect type is easy to reason about. When
  effects mix, the order matters, partial failures become possible,
  and testing gets harder.

      mix reach.boundaries
      mix reach.boundaries --format json
      mix reach.boundaries --min 3

  ## Options

    * `--format` — output format: `text` (default), `json`, `oneline`
    * `--min` — minimum number of distinct effects (default: 2)

  """

  use Mix.Task

  alias Reach.CLI.Format
  alias Reach.CLI.Project
  alias Reach.Effects
  alias Reach.IR

  @shortdoc "Functions with multiple distinct side effects"

  @switches [format: :string, min: :integer]
  @aliases [f: :format]

  @impl Mix.Task
  def run(args) do
    {opts, args, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)
    format = opts[:format] || "text"
    min = opts[:min] || 2
    path = List.first(args)

    project = Project.load()
    findings = analyze(project, min)
    findings = Enum.filter(findings, &Project.file_matches?(&1.file, path))

    case format do
      "json" ->
        Format.render(%{findings: findings}, "reach.boundaries", format: "json", pretty: true)

      "oneline" ->
        render_oneline(findings)

      _ ->
        render_text(findings)
    end
  end

  defp analyze(project, min) do
    nodes = Map.values(project.nodes)
    mod_defs = Enum.filter(nodes, &(&1.type == :module_def))

    mod_defs
    |> Enum.flat_map(&analyze_module(&1, min))
    |> Enum.sort_by(fn f -> -length(f.effects) end)
  end

  defp analyze_module(m, min) do
    mod_name = m.meta[:name]

    m
    |> IR.all_nodes()
    |> Enum.filter(&(&1.type == :function_def))
    |> Enum.flat_map(&analyze_function(&1, mod_name, min))
  end

  defp analyze_function(f, mod_name, min) do
    calls = f |> IR.all_nodes() |> Enum.filter(&(&1.type == :call))

    effects =
      calls
      |> Enum.map(&Effects.classify/1)
      |> MapSet.new()
      |> MapSet.delete(:pure)
      |> MapSet.delete(:unknown)

    if MapSet.size(effects) >= min do
      effect_calls =
        calls
        |> Enum.reject(&(Effects.classify(&1) in [:pure, :unknown]))
        |> Enum.map(fn c -> %{effect: Effects.classify(c), call: call_name(c)} end)
        |> Enum.uniq_by(& &1.call)
        |> Enum.sort_by(&to_string(&1.effect))

      [
        %{
          module: inspect(mod_name),
          function: "#{f.meta[:name]}/#{f.meta[:arity]}",
          effects: MapSet.to_list(effects) |> Enum.sort(),
          calls: effect_calls,
          file: if(f.source_span, do: f.source_span.file),
          line: if(f.source_span, do: f.source_span.start_line)
        }
      ]
    else
      []
    end
  end

  defp call_name(node), do: Format.call_name(node)

  # --- Rendering ---

  defp render_text(findings) do
    IO.puts(Format.header("Effect Boundaries (#{length(findings)})"))

    if findings == [] do
      IO.puts("  (no mixed-effect functions found)\n")
    else
      Enum.each(findings, fn f ->
        effects_str = Enum.map_join(f.effects, " + ", &effect_color/1)

        IO.puts("  #{Format.bright("#{f.module}.#{f.function}")}  #{effects_str}")

        Enum.each(f.calls, fn c ->
          IO.puts("    #{effect_color(c.effect)} #{c.call}")
        end)

        # credo:disable-for-next-line Credo.Check.Refactor.Nesting
        if f.file do
          IO.puts("    #{Format.faint("#{f.file}:#{f.line}")}")
        end
      end)

      IO.puts("\n#{Format.count(length(findings))} function(s)\n")
    end
  end

  defp render_oneline(findings) do
    Enum.each(findings, fn f ->
      effects = Enum.join(f.effects, "+")
      loc = if f.file && f.line, do: "#{f.file}:#{f.line}", else: ""
      IO.puts("#{f.module}.#{f.function}\t#{effects}\t#{loc}")
    end)
  end

  defp effect_color(:write), do: Format.red("write")
  defp effect_color(:send), do: Format.yellow("send")
  defp effect_color(:io), do: Format.yellow("io")
  defp effect_color(:read), do: Format.cyan("read")
  defp effect_color(:exception), do: Format.red("exception")
  defp effect_color(:nif), do: Format.red("nif")
  defp effect_color(:receive), do: Format.yellow("receive")
  defp effect_color(other), do: to_string(other)
end
