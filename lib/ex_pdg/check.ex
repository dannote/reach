defmodule ExPDG.Check do
  @moduledoc """
  Behaviour and macro for defining PDG-based checks.

  Checks are named queries with metadata (severity, category, message)
  that produce `ExPDG.Diagnostic` structs.

  ## Using the behaviour directly

      defmodule MyCheck do
        @behaviour ExPDG.Check

        @impl true
        def meta, do: %{severity: :warning, category: :code_quality}

        @impl true
        def run(graph, _opts) do
          import ExPDG.Query
          for node <- nodes(graph, type: :call),
              pure?(node),
              not has_dependents?(graph, node.id) do
            %ExPDG.Diagnostic{
              check: __MODULE__,
              severity: :warning,
              message: "Pure call result is unused",
              location: node.source_span,
              node_id: node.id
            }
          end
        end
      end

  ## Using the `check` macro

      defmodule MyChecks do
        use ExPDG.Check

        check :useless_expression,
          severity: :warning,
          category: :code_quality do
          for node <- nodes(graph, type: :call),
              pure?(node),
              not has_dependents?(graph, node.id) do
            diagnostic("Pure call result is unused", node)
          end
        end
      end
  """

  alias ExPDG.Diagnostic

  @callback meta() :: %{severity: Diagnostic.severity(), category: atom()}
  @callback run(ExPDG.Graph.t(), keyword()) :: [Diagnostic.t()]

  defmacro __using__(_opts) do
    quote do
      import ExPDG.Query
      import ExPDG.Check, only: [check: 3]

      @behaviour ExPDG.Check
      @before_compile ExPDG.Check

      Module.register_attribute(__MODULE__, :check_names, accumulate: true)

      @impl ExPDG.Check
      def meta, do: %{severity: :warning, category: :general}

      @impl ExPDG.Check
      def run(graph, opts \\ []) do
        Enum.flat_map(__check_names__(), fn name ->
          apply(__MODULE__, :"__check_#{name}__", [graph, opts])
        end)
      end

      defoverridable meta: 0, run: 2
    end
  end

  defmacro __before_compile__(env) do
    names = Module.get_attribute(env.module, :check_names)

    quote do
      def __check_names__, do: unquote(names)
    end
  end

  @doc """
  Defines a named check.

  The body receives `graph` (the PDG) and should return a list of
  `ExPDG.Diagnostic` structs. Inside the body:

  - `graph` — the `ExPDG.Graph.t()` being analyzed
  - `diagnostic(message, node)` — shortcut to build a `Diagnostic`
  - All `ExPDG.Query` functions are imported
  """
  defmacro check(name, opts, do: body) do
    severity = Keyword.get(opts, :severity, :warning)
    category = Keyword.get(opts, :category, :general)
    func_name = :"__check_#{name}__"

    quote do
      @check_names unquote(name)

      def unquote(func_name)(var!(graph), _opts) do
        diagnostic = fn message, node ->
          %ExPDG.Diagnostic{
            check: unquote(name),
            severity: unquote(severity),
            category: unquote(category),
            message: message,
            location: node.source_span,
            node_id: node.id
          }
        end

        var!(diagnostic) = diagnostic

        result = unquote(body)

        case result do
          list when is_list(list) -> list
          _ -> []
        end
      end
    end
  end

  @doc """
  Runs a list of check modules against a graph.
  """
  @spec run_checks([module()], ExPDG.Graph.t() | ExPDG.SystemDependence.t(), keyword()) :: [
          Diagnostic.t()
        ]
  def run_checks(check_modules, graph, opts \\ []) do
    Enum.flat_map(check_modules, fn mod ->
      mod.run(graph, opts)
    end)
  end
end
