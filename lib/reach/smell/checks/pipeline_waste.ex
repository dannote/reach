defmodule Reach.Smell.Checks.PipelineWaste do
  @moduledoc "Pattern-based detection of redundant pipeline operations."

  use Reach.Smell.PatternCheck

  smell(
    ~p[Enum.reverse(_) |> Enum.reverse()],
    :redundant_traversal,
    "Enum.reverse → Enum.reverse is a no-op"
  )

  smell(
    ~p[Enum.filter(_, _) |> Enum.count()],
    :suboptimal,
    "Enum.filter → Enum.count: use Enum.count/2 instead"
  )

  smell(
    ~p[Enum.map(_, _) |> Enum.count()],
    :suboptimal,
    "Enum.map → Enum.count: use Enum.count/2 with transform"
  )

  smell(
    ~p[Enum.map(_, _) |> List.first()],
    :eager_pattern,
    "Enum.map → List.first: builds entire list for one element; use Enum.find_value/2"
  )

  smell(
    ~p[Enum.sort(_) |> Enum.take(_)],
    :eager_pattern,
    "Enum.sort → Enum.take: sorts entire list; use Enum.min/max or partial top-k"
  )

  smell(
    ~p[Enum.sort(_, _) |> Enum.take(_)],
    :eager_pattern,
    "Enum.sort → Enum.take: sorts entire list; use Enum.min/max or partial top-k"
  )

  smell(
    ~p[Enum.sort(_) |> Enum.reverse()],
    :eager_pattern,
    "Enum.sort → Enum.reverse: use Enum.sort(enumerable, :desc)"
  )

  smell(
    ~p[Enum.sort(_) |> Enum.at(_)],
    :eager_pattern,
    "Enum.sort → Enum.at: full sort for one element; use Enum.min/max"
  )

  smell(
    ~p[Enum.drop(_, _) |> Enum.take(_)],
    :eager_pattern,
    "Enum.drop → Enum.take: use Enum.slice/3"
  )

  smell(
    ~p[Enum.take_while(_, _) |> Enum.count()],
    :eager_pattern,
    "Enum.take_while → Enum.count: allocates an intermediate list; use Enum.reduce_while/3"
  )

  smell(
    ~p[Enum.take_while(_, _) |> length()],
    :eager_pattern,
    "Enum.take_while → length: allocates an intermediate list; use Enum.reduce_while/3"
  )

  smell(
    ~p[Enum.map(_, _) |> Enum.join()],
    :eager_pattern,
    "Enum.map → Enum.join: use Enum.map_join/3"
  )

  smell(
    ~p[Enum.map(_, _) |> Enum.join(_)],
    :eager_pattern,
    "Enum.map → Enum.join: use Enum.map_join/3"
  )

  smell(
    ~p[_ |> (fn _ -> _ end).()],
    :suboptimal,
    "anonymous fn applied with .() in pipe; use then/2 instead"
  )

  smell(
    ~p[Enum.map(_, _) |> Enum.max()],
    :eager_pattern,
    "Enum.map → Enum.max: allocates intermediate list; use Enum.max_by/2"
  )

  smell(
    ~p[Enum.map(_, _) |> Enum.min()],
    :eager_pattern,
    "Enum.map → Enum.min: allocates intermediate list; use Enum.min_by/2"
  )

  smell(
    ~p[Enum.map(_, _) |> Enum.sum()],
    :eager_pattern,
    "Enum.map → Enum.sum: allocates intermediate list; use Enum.sum_by/2 or Enum.reduce/3"
  )

  smell(
    ~p[List.foldl(_, _, _)],
    :suboptimal,
    "List.foldl/3 is non-idiomatic; use Enum.reduce/3"
  )

  smell(
    ~p[List.foldr(_, _, _)],
    :suboptimal,
    "List.foldr/3 is non-idiomatic; use Enum.reduce/3 (consider reversal semantics)"
  )
end
