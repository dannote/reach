defmodule ExPDG.Frontend.BEAM do
  @moduledoc false
  alias ExPDG.IR.Counter

  alias ExPDG.Frontend.Erlang

  @spec from_bytecode(binary(), keyword()) :: {:ok, [ExPDG.IR.Node.t()]} | {:error, term()}
  def from_bytecode(bytecode, opts \\ []) when is_binary(bytecode) do
    with {:error, _} <- from_abstract_code(bytecode, opts),
         {:error, _} <- from_debug_info(bytecode, opts) do
      {:error, :no_debug_info}
    end
  end

  @spec from_module(module(), keyword()) :: {:ok, [ExPDG.IR.Node.t()]} | {:error, term()}
  def from_module(module, opts \\ []) when is_atom(module) do
    case :code.which(module) do
      :non_existing ->
        {:error, :module_not_found}

      path ->
        case File.read(path) do
          {:ok, bytecode} ->
            from_bytecode(bytecode, Keyword.put_new(opts, :file, to_string(path)))

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @spec from_compiled_string(String.t(), keyword()) ::
          {:ok, [ExPDG.IR.Node.t()]} | {:error, term()}
  def from_compiled_string(source, opts \\ []) do
    tmp_dir = Path.join(System.tmp_dir!(), "ex_pdg_beam_#{:erlang.unique_integer([:positive])}")

    try do
      File.mkdir_p!(tmp_dir)
      tmp_file = Path.join(tmp_dir, "source.ex")
      File.write!(tmp_file, source)

      prev = Code.get_compiler_option(:debug_info)
      Code.put_compiler_option(:debug_info, true)

      {:ok, modules, _} = Kernel.ParallelCompiler.compile_to_path([tmp_file], tmp_dir)

      Code.put_compiler_option(:debug_info, prev)

      nodes =
        Enum.flat_map(modules, fn mod ->
          beam_path = Path.join(tmp_dir, Atom.to_string(mod) <> ".beam")

          case File.read(beam_path) do
            {:ok, bytecode} ->
              case from_bytecode(bytecode, opts) do
                {:ok, n} -> n
                {:error, _} -> []
              end

            {:error, _} ->
              []
          end
        end)

      {:ok, nodes}
    rescue
      e -> {:error, {e.__struct__, Exception.message(e)}}
    after
      File.rm_rf(tmp_dir)
    end
  end

  @spec from_compiled_modules([{module(), binary()}], keyword()) :: {:ok, [ExPDG.IR.Node.t()]}
  def from_compiled_modules(compiled, opts \\ []) do
    nodes =
      Enum.flat_map(compiled, fn {_module, bytecode} ->
        case from_bytecode(bytecode, opts) do
          {:ok, n} -> n
          {:error, _} -> []
        end
      end)

    {:ok, nodes}
  end

  defp from_abstract_code(bytecode, opts) do
    case :beam_lib.chunks(bytecode, [:abstract_code]) do
      {:ok, {module, [{:abstract_code, {:raw_abstract_v1, forms}}]}} ->
        translate_forms(forms, Keyword.put_new(opts, :file, to_string(module)))

      _ ->
        {:error, :no_abstract_code}
    end
  end

  defp from_debug_info(bytecode, opts) do
    case :beam_lib.chunks(bytecode, [:debug_info]) do
      {:ok, {module, [{:debug_info, {:debug_info_v1, backend, data}}]}} ->
        case backend.debug_info(:erlang_v1, module, data, []) do
          {:ok, forms} ->
            translate_forms(forms, Keyword.put_new(opts, :file, to_string(module)))

          _ ->
            {:error, :debug_info_decode_failed}
        end

      _ ->
        {:error, :no_debug_info}
    end
  end

  defp translate_forms(forms, opts) do
    file = Keyword.get(opts, :file, "nofile")
    counter = Counter.new()

    nodes =
      forms
      |> Enum.reject(fn
        {:eof, _} -> true
        {:attribute, _, :file, _} -> true
        {:function, _, :__info__, _, _} -> true
        {:function, _, :module_info, _, _} -> true
        _ -> false
      end)
      |> Enum.map(&Erlang.translate_form(&1, counter, file))

    {:ok, nodes}
  end
end
