defmodule Reach.Smell.PatternCheck do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      @behaviour Reach.Smell.Check
      @before_compile Reach.Smell.PatternCheck

      import ExAST.Sigil
      import ExAST.Query
      import Reach.Smell.PatternCheck, only: [smell: 3]

      Module.register_attribute(__MODULE__, :smell_patterns, accumulate: true)
      Module.register_attribute(__MODULE__, :smell_query_names, accumulate: true)

      @impl true
      def run(project) do
        project.nodes
        |> Map.values()
        |> Enum.filter(&(&1.type == :module_def))
        |> Enum.flat_map(&scan_module/1)
      end

      defp scan_module(module) do
        file = module.source_span && module.source_span[:file]

        if file && File.regular?(file) do
          zipper = cached_zipper(file)
          find_pattern_smells(zipper, file) ++ find_query_smells(zipper, file)
        else
          []
        end
      rescue
        _ -> []
      end

      defp cached_zipper(file) do
        key = {:reach_smell_zipper, file}

        case Process.get(key) do
          nil ->
            zipper =
              file
              |> File.read!()
              |> Sourceror.parse_string!()
              |> Sourceror.Zipper.zip()

            Process.put(key, zipper)
            zipper

          zipper ->
            zipper
        end
      end
    end
  end

  defmacro smell(pattern, kind, message) do
    if selector_ast?(pattern) do
      idx = Module.get_attribute(__CALLER__.module, :smell_query_counter) || 0
      Module.put_attribute(__CALLER__.module, :smell_query_counter, idx + 1)
      fun_name = :"__smell_query_#{idx}__"

      quote do
        @smell_query_names {unquote(fun_name), unquote(kind), unquote(message)}
        @doc false
        @dialyzer {:nowarn_function, [{unquote(fun_name), 0}]}
        def unquote(fun_name)(), do: unquote(pattern)
      end
    else
      quote do
        @smell_patterns {unquote(pattern), unquote(kind), unquote(message)}
      end
    end
  end

  defp selector_ast?({:|>, _, [left, _]}), do: selector_ast?(left)
  defp selector_ast?({:from, _, _}), do: true
  defp selector_ast?(_), do: false

  defmacro __before_compile__(_env) do
    quote do
      defp find_pattern_smells(zipper, file) do
        named =
          @smell_patterns
          |> Enum.with_index()
          |> Map.new(fn {{pattern, _kind, _message}, idx} ->
            {:"p#{idx}", pattern}
          end)

        meta =
          @smell_patterns
          |> Enum.with_index()
          |> Map.new(fn {{_pattern, kind, message}, idx} ->
            {:"p#{idx}", {kind, message}}
          end)

        zipper
        |> ExAST.Patcher.find_many(named)
        |> Enum.map(fn match ->
          {kind, message} = Map.fetch!(meta, match.pattern)
          line = (match.range && match.range.start[:line]) || 0
          Reach.Smell.Finding.new(kind: kind, message: message, location: "#{file}:#{line}")
        end)
      end

      defp find_query_smells(zipper, file) do
        Enum.flat_map(@smell_query_names, fn {fun_name, kind, message} ->
          zipper
          |> ExAST.Patcher.find_all(apply(__MODULE__, fun_name, []))
          |> Enum.map(fn match ->
            line = (match.range && match.range.start[:line]) || 0
            Reach.Smell.Finding.new(kind: kind, message: message, location: "#{file}:#{line}")
          end)
        end)
      end
    end
  end
end
