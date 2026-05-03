defmodule Reach.CLI.Commands.Inspect do
  @moduledoc """
  Explains one function, module, file, or line.

      mix reach.inspect Reach.Frontend.Elixir.translate/3
      mix reach.inspect lib/reach/frontend/elixir.ex:54
      mix reach.inspect TARGET --deps
      mix reach.inspect TARGET --impact
      mix reach.inspect TARGET --slice
      mix reach.inspect TARGET --graph
      mix reach.inspect TARGET --call-graph
      mix reach.inspect TARGET --data
      mix reach.inspect TARGET --context
      mix reach.inspect TARGET --candidates
      mix reach.inspect TARGET --why OTHER

  ## Options

    * `--format` — output format passed to delegated analyses: `text`, `json`, `oneline`
    * `--deps` — callers, callees, and shared state
    * `--impact` — direct/transitive change impact
    * `--slice` — backward program slice
    * `--forward` — use a forward slice with `--slice` or `--data`
    * `--graph` — render graph output where supported
    * `--call-graph` — render the call graph around the target
    * `--data` — target-local data-flow view
    * `--context` — agent-readable bundle: deps, impact, data, effects
    * `--candidates` — advisory placeholder for graph-backed refactoring candidates
    * `--why` — explain the shortest graph-backed relationship to another target
    * `--depth` — transitive depth passed to deps/impact
    * `--variable` — variable filter passed to slice/data views
    * `--limit` — text display limit for truncated context sections
    * `--all` — show all text rows in context output

  """

  alias Reach.CLI.BoxartGraph
  alias Reach.CLI.Commands.Inspect.Deps
  alias Reach.CLI.Commands.Inspect.Impact
  alias Reach.CLI.Commands.Trace.Slice
  alias Reach.CLI.Project
  alias Reach.CLI.Render.Inspect, as: InspectRender
  alias Reach.Inspect.{Candidates, Context, Data, Why}
  alias Reach.IR.Helpers, as: IRHelpers
  alias Reach.Project.Query

  def run(opts, target_args \\ []) do
    target =
      List.first(target_args) || Mix.raise("Expected a target. Usage: mix reach.inspect TARGET")

    run_action(inspect_action(opts), target, opts)
  end

  defp inspect_action(opts) do
    [
      {opts[:context], :context},
      {opts[:why] != nil, :why},
      {opts[:candidates], :candidates},
      {opts[:impact], :impact},
      {opts[:deps], :deps},
      {opts[:data] == true and opts[:format] == "json", :data},
      {opts[:data] == true and opts[:graph] != true, :data},
      {opts[:slice] == true or opts[:data] == true, :slice},
      {opts[:call_graph], :call_graph},
      {opts[:graph], :graph}
    ]
    |> Enum.find_value(:context, fn
      {true, action} -> action
      {_enabled, _action} -> nil
    end)
  end

  defp run_action(:context, target, opts), do: run_context(target, opts)
  defp run_action(:why, target, opts), do: run_why(target, opts)
  defp run_action(:candidates, target, opts), do: run_candidates(target, opts)
  defp run_action(:impact, target, opts), do: Impact.run_target(target, opts, "reach.inspect")
  defp run_action(:deps, target, opts), do: Deps.run_target(target, opts, "reach.inspect")

  defp run_action(:call_graph, target, opts),
    do: Deps.run_target(target, Keyword.put(opts, :graph, true), "reach.inspect")

  defp run_action(:graph, target, opts), do: render_cfg(target, opts)
  defp run_action(:data, target, opts), do: run_data(target, opts)

  defp run_action(:slice, target, opts),
    do: Slice.run_target(target, opts, command: "reach.inspect")

  defp run_why(target, opts) do
    project = Project.load(quiet: opts[:format] == "json")
    result = Why.result(project, target, opts[:why], opts[:depth] || 6)
    InspectRender.render_why(result, opts[:format] || "text")
  end

  defp run_context(target, opts) do
    project = load_target_project(target, opts)
    {mfa, func} = resolve_function!(project, target)

    if opts[:format] == "json" do
      context = Context.build(project, mfa, func, opts)
      InspectRender.render_context(context, "json")
    else
      InspectRender.render_context(
        context_text_data(project, mfa, func, opts),
        "text",
        display_limit(opts)
      )
    end
  end

  defp context_text_data(project, mfa, func, opts) do
    %{
      mfa: mfa,
      func: func,
      data: Data.summary(project, func, opts[:variable]),
      direct_callers: Query.callers(project, mfa, 1),
      transitive_callers: Query.callers(project, mfa, opts[:depth] || 4),
      callees: Query.callees(project, mfa, opts[:depth] || 3)
    }
  end

  defp display_limit(opts) do
    cond do
      opts[:all] -> :all
      is_integer(opts[:limit]) and opts[:limit] > 0 -> opts[:limit]
      true -> 20
    end
  end

  defp run_data(target, opts) do
    project = load_target_project(target, opts)
    {mfa, func} = resolve_function!(project, target)
    summary = Data.summary(project, func, opts[:variable])
    InspectRender.render_data(summary, mfa, func, opts[:format] || "text")
  end

  defp render_cfg(target, opts) do
    BoxartGraph.require!()

    {{_mod, fun, arity}, func} = resolve_graph_target!(target, opts)
    file = func.source_span && func.source_span.file

    InspectRender.render_cfg_header(fun, arity)

    if file do
      BoxartGraph.render_cfg(func, file)
    else
      InspectRender.render_missing_source()
    end
  end

  defp resolve_graph_target!(target, opts) do
    case Query.parse_file_line(target) do
      {file, line} ->
        project = Project.load(paths: [file], quiet: opts[:format] == "json")
        func = Query.find_function_at_location(project, file, line)

        if func do
          {{func.meta[:module], func.meta[:name], func.meta[:arity]}, func}
        else
          Mix.raise("Function not found: #{target}")
        end

      nil ->
        project = Project.load(quiet: opts[:format] == "json")
        resolve_function!(project, target)
    end
  end

  defp load_target_project(target, opts) do
    case Query.parse_file_line(target) do
      {file, _line} -> Project.load(paths: [file], quiet: opts[:format] == "json")
      nil -> Project.load(quiet: opts[:format] == "json")
    end
  end

  defp resolve_function!(project, raw) do
    case Query.parse_file_line(raw) do
      {file, line} ->
        func =
          Query.find_function_at_location(project, file, line) ||
            Mix.raise("Function not found at #{raw}")

        {{func.meta[:module], func.meta[:name], func.meta[:arity]}, func}

      nil ->
        mfa = Query.resolve_target(project, raw) || Mix.raise("Function not found: #{raw}")

        func =
          Query.find_function(project, mfa) ||
            Mix.raise("Function definition not found in IR: #{raw}")

        {mfa, func}
    end
  end

  defp run_candidates(target, opts) do
    project = load_target_project(target, opts)
    {mfa, func} = resolve_function!(project, target)
    target_string = IRHelpers.func_id_to_string(mfa)

    candidates =
      Enum.map(Candidates.find(project, mfa, func), &Map.put(&1, :target, target_string))

    result = %{
      command: "reach.inspect",
      target: target_string,
      candidates: candidates,
      note: "Candidates are advisory. Prove behavior preservation before editing."
    }

    InspectRender.render_candidates(result, opts[:format] || "text")
  end
end
