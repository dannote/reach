defmodule Reach.Plugin do
  @moduledoc """
  Behaviour for library-specific analysis plugins.

  Plugins extend Reach in two ways:

  1. **Graph edges** — `analyze/2` and `analyze_project/3` add domain-specific
     edges to the dependence graph (framework dispatch, message routing, etc.)

  2. **Effect classification** — `classify_effect/1` teaches the effect
     classifier about framework-specific calls (Ecto queries are pure,
     Repo writes are `:write`, etc.)

  ## Implementing a plugin

      defmodule MyPlugin do
        @behaviour Reach.Plugin

        @impl true
        def analyze(all_nodes, _opts), do: []

        @impl true
        def classify_effect(%Reach.IR.Node{type: :call, meta: %{function: :my_pure_fn}}), do: :pure
        def classify_effect(_), do: nil
      end

  ## Built-in plugins

  Plugins for Phoenix, Ecto, Oban, GenStage, Jido, and OpenTelemetry
  are included and auto-detected at runtime. Override with the
  `:plugins` option:

      Reach.Project.from_mix_project(plugins: [Reach.Plugins.Ecto])

  Disable auto-detection:

      Reach.string_to_graph!(source, plugins: [])
  """

  alias Reach.IR.Node

  @type edge_spec :: {Node.id(), Node.id(), term()}

  @doc """
  Analyzes IR nodes from a single module and returns edges to add.
  """
  @callback analyze(all_nodes :: [Node.t()], opts :: keyword()) :: [edge_spec()]

  @doc """
  Analyzes IR nodes across all modules in a project.

  Only needed for cross-module patterns like router→controller
  dispatch or job enqueue→perform flow.
  """
  @callback analyze_project(
              modules :: %{module() => map()},
              all_nodes :: [Node.t()],
              opts :: keyword()
            ) :: [edge_spec()]

  @doc """
  Classifies the effect of a call node.

  Return an effect atom (`:pure`, `:read`, `:write`, `:io`, `:send`,
  `:exception`) or `nil` to defer to the next classifier.
  """
  @callback classify_effect(node :: Node.t()) :: atom() | nil

  @optional_callbacks analyze_project: 3, classify_effect: 1

  @known_plugins [
    {Phoenix.Router, Reach.Plugins.Phoenix},
    {Ecto, Reach.Plugins.Ecto},
    {Oban, Reach.Plugins.Oban},
    {GenStage, Reach.Plugins.GenStage},
    {Jido.Action, Reach.Plugins.Jido},
    {OpenTelemetry.Tracer, Reach.Plugins.OpenTelemetry}
  ]

  @doc """
  Returns the list of auto-detected plugins based on loaded dependencies.
  """
  def detect do
    for {mod, plugin} <- @known_plugins,
        Code.ensure_loaded?(mod) do
      plugin
    end
  end

  @doc """
  Resolves plugins from options, falling back to auto-detection.
  """
  def resolve(opts) do
    case Keyword.get(opts, :plugins) do
      nil -> detect()
      [] -> []
      list when is_list(list) -> list
    end
  end

  @doc """
  Asks each plugin to classify a call node's effect.

  Returns the first non-nil result, or `nil` if no plugin matches.
  """
  def classify_effect(plugins, node) do
    Enum.find_value(plugins, fn plugin ->
      if Code.ensure_loaded?(plugin) and function_exported?(plugin, :classify_effect, 1) do
        plugin.classify_effect(node)
      end
    end)
  end

  @doc false
  def run_analyze(plugins, all_nodes, opts) do
    Enum.flat_map(plugins, fn plugin ->
      plugin.analyze(all_nodes, opts)
    end)
  end

  @doc false
  def run_analyze_project(plugins, modules, all_nodes, opts) do
    Enum.flat_map(plugins, fn plugin ->
      if Code.ensure_loaded?(plugin) and function_exported?(plugin, :analyze_project, 3) do
        plugin.analyze_project(modules, all_nodes, opts)
      else
        []
      end
    end)
  end
end
