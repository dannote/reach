defmodule Reach.Smell.Checks.ConfigPhase do
  @moduledoc false

  use Reach.Smell.PatternCheck

  smell(
    ~p[@_ Application.get_env(_, _)],
    :config_phase,
    "module attribute calls Application.get_env at compile time; use Application.compile_env or read at runtime"
  )

  smell(
    ~p[@_ Application.fetch_env(_, _)],
    :config_phase,
    "module attribute calls Application.fetch_env at compile time; use Application.compile_env or read at runtime"
  )

  smell(
    ~p[@_ Application.fetch_env!(_, _)],
    :config_phase,
    "module attribute calls Application.fetch_env! at compile time; use Application.compile_env! or read at runtime"
  )

  smell(
    from(~p[Application.compile_env(_, _)]) |> where(inside("def _ do ... end")),
    :config_phase,
    "Application.compile_env inside a function is still compile-time; use Application.get_env for runtime config"
  )

  smell(
    from(~p[Application.compile_env!(_, _)]) |> where(inside("def _ do ... end")),
    :config_phase,
    "Application.compile_env! inside a function is still compile-time; use Application.fetch_env! for runtime config"
  )

  smell(
    from(~p[Application.compile_env(_, _, _)]) |> where(inside("def _ do ... end")),
    :config_phase,
    "Application.compile_env inside a function is still compile-time; use Application.get_env for runtime config"
  )

  smell(
    from(~p[Application.compile_env!(_, _, _)]) |> where(inside("def _ do ... end")),
    :config_phase,
    "Application.compile_env! inside a function is still compile-time; use Application.fetch_env! for runtime config"
  )
end
