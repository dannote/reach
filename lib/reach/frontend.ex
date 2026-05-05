defmodule Reach.Frontend do
  @moduledoc false

  alias Reach.Frontend.Elixir, as: ElixirFrontend
  alias Reach.Frontend.Erlang, as: ErlangFrontend

  @core_extensions %{
    ".ex" => :elixir,
    ".exs" => :elixir,
    ".erl" => :erlang,
    ".hrl" => :erlang
  }

  @optional_frontends [
    Reach.Frontend.Gleam,
    Reach.Frontend.JavaScript
  ]

  def language_from_path(path) do
    ext = Path.extname(path)
    Map.get(@core_extensions, ext) || optional_language(ext) || :elixir
  end

  def source_extensions do
    Map.keys(@core_extensions) ++ optional_extensions()
  end

  def parse_file(path, opts \\ []) do
    case language_from_path(path) do
      :elixir -> parse_elixir(path, opts)
      :erlang -> ErlangFrontend.parse_file(path, opts)
      language -> parse_optional(language, path, opts)
    end
  end

  defp parse_elixir(path, opts) do
    case File.read(path) do
      {:ok, source} -> ElixirFrontend.parse(source, Keyword.put(opts, :file, path))
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_optional(language, path, opts) do
    case find_frontend(language) do
      nil -> {:error, {:frontend_not_available, language}}
      module -> module.parse_file(path, opts)
    end
  end

  defp optional_language(ext) do
    Enum.find_value(@optional_frontends, fn module ->
      if available?(module) and ext in module.extensions(), do: language_atom(module)
    end)
  end

  defp optional_extensions do
    for module <- @optional_frontends,
        available?(module),
        ext <- module.extensions(),
        do: ext
  end

  defp find_frontend(language) do
    Enum.find(@optional_frontends, fn module ->
      available?(module) and language_atom(module) == language
    end)
  end

  defp available?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :extensions, 0)
  end

  defp language_atom(Reach.Frontend.Gleam), do: :gleam
  defp language_atom(Reach.Frontend.JavaScript), do: :javascript
  defp language_atom(_), do: nil
end
