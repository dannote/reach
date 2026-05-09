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
    ~p[Enum.join(_, "")],
    :suboptimal,
    ~S[Enum.join/1 defaults to empty separator; remove the "" argument]
  )

  smell(
    ~p[Enum.map_join(_, "", _)],
    :suboptimal,
    ~S[Enum.map_join/3 defaults to empty separator; remove the "" argument]
  )

  smell(
    ~p[Enum.with_index(_) |> Enum.reduce(_, _)],
    :eager_pattern,
    "Enum.with_index/1 before Enum.reduce/3 builds index pairs eagerly; use Stream.with_index/1"
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
    "List.foldr/3 is non-idiomatic; use Enum.reduce/3 (with Enum.reverse if order matters)"
  )

  # Enum._by with identity function
  smell(
    ~p[Enum.uniq_by(_, fn x -> x end)],
    :suboptimal,
    "Enum.uniq_by with identity function; use Enum.uniq/1"
  )

  smell(
    ~p[Enum.sort_by(_, fn x -> x end)],
    :suboptimal,
    "Enum.sort_by with identity function; use Enum.sort/1"
  )

  smell(
    ~p[Enum.min_by(_, fn x -> x end)],
    :suboptimal,
    "Enum.min_by with identity function; use Enum.min/1"
  )

  smell(
    ~p[Enum.max_by(_, fn x -> x end)],
    :suboptimal,
    "Enum.max_by with identity function; use Enum.max/1"
  )

  smell(
    ~p[Enum.dedup_by(_, fn x -> x end)],
    :suboptimal,
    "Enum.dedup_by with identity function; use Enum.dedup/1"
  )

  smell(
    ~p[Enum.filter(_, _) |> Enum.filter(_, _)],
    :eager_pattern,
    "Enum.filter → Enum.filter: combine predicates into one Enum.filter/2 call"
  )

  smell(
    ~p[Enum.map(_, _) |> Enum.flat_map(_)],
    :eager_pattern,
    "Enum.map → Enum.flat_map: use Enum.flat_map/2 directly"
  )

  smell(
    ~p[Enum.map(_, _) |> List.flatten()],
    :eager_pattern,
    "Enum.map → List.flatten: use Enum.flat_map/2 directly"
  )

  smell(
    ~p[Enum.filter(_, _) |> Enum.map(_, _)],
    :eager_pattern,
    "Enum.filter → Enum.map: consider combining into a single Enum.flat_map/2 or for comprehension"
  )

  smell(
    ~p[Enum.sort(_, _) |> Enum.reverse()],
    :eager_pattern,
    "Enum.sort/2 → Enum.reverse: pass the opposite sort direction instead"
  )
end
