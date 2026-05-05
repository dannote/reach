defmodule Reach.Smell.Checks.CollectionIdioms do
  @moduledoc "Pattern-based detection of suboptimal collection operations."

  use Reach.Smell.PatternCheck

  smell(
    ~p[Enum.join(_, "")],
    :suboptimal,
    ~S[Enum.join/1 defaults to empty separator; remove the "" argument]
  )

  smell(
    ~p[Enum.reverse(_) |> hd()],
    :suboptimal,
    "Enum.reverse/1 |> hd() traverses twice; use List.last/1"
  )

  smell(
    ~p[Enum.reverse(_) |> List.first()],
    :suboptimal,
    "Enum.reverse/1 |> List.first/1 traverses twice; use List.last/1"
  )

  smell(
    ~p[Enum.reverse(_) ++ _],
    :suboptimal,
    "Enum.reverse(list) ++ tail traverses twice; use Enum.reverse(list, tail)"
  )

  smell(
    ~p[String.graphemes(_) |> length()],
    :suboptimal,
    "String.graphemes/1 |> length/1 builds an intermediate list; use String.length/1"
  )

  smell(
    ~p[String.graphemes(_) |> Enum.count()],
    :suboptimal,
    "String.graphemes/1 |> Enum.count/1 builds an intermediate list; use String.length/1"
  )

  smell(
    ~p[Integer.to_string(_, _) |> String.to_charlist()],
    :suboptimal,
    "Integer.to_string/2 → String.to_charlist/1; prefer Integer.digits/2"
  )

  smell(
    ~p[String.length(_) == 1],
    :suboptimal,
    "String.length/1 traverses the whole string to check for one character; use pattern matching"
  )

  smell(
    ~p[1 == String.length(_)],
    :suboptimal,
    "String.length/1 traverses the whole string to check for one character; use pattern matching"
  )

  smell(
    ~p[String.length(_) != 1],
    :suboptimal,
    "String.length/1 traverses the whole string to check for one character; use pattern matching"
  )

  smell(
    ~p[1 != String.length(_)],
    :suboptimal,
    "String.length/1 traverses the whole string to check for one character; use pattern matching"
  )

  smell(
    ~p[inspect(_) |> String.starts_with?(_)],
    :suboptimal,
    "inspect/1 for module/atom membership is fragile; use Module.split/1 or direct atom comparison"
  )

  smell(
    ~p[inspect(_) |> String.contains?(_)],
    :suboptimal,
    "inspect/1 for type checking is fragile; compare atoms or use Module.split/1"
  )

  smell(
    ~p[Map.keys(_) |> Enum.map(_)],
    :suboptimal,
    "Map.keys/1 → Enum.map: iterate the map directly as {key, value} pairs"
  )

  smell(
    ~p[Map.keys(_) |> Enum.filter(_)],
    :suboptimal,
    "Map.keys/1 → Enum.filter: iterate the map directly as {key, value} pairs"
  )

  smell(
    ~p[Map.keys(_) |> Enum.each(_)],
    :suboptimal,
    "Map.keys/1 → Enum.each: iterate the map directly as {key, value} pairs"
  )

  smell(
    ~p[Map.keys(_) |> Enum.flat_map(_)],
    :suboptimal,
    "Map.keys/1 → Enum.flat_map: iterate the map directly as {key, value} pairs"
  )

  smell(
    ~p[List.to_tuple(_) |> elem(_)],
    :suboptimal,
    "List.to_tuple/1 → elem/2 allocates a full copy; use Enum.at/2 or pattern matching"
  )

  smell(
    ~p[String.graphemes(_) |> Enum.reverse() |> Enum.join()],
    :suboptimal,
    "String.graphemes |> Enum.reverse |> Enum.join; use String.reverse/1"
  )

  smell(
    ~p[Map.values(_) |> Enum.all?(_)],
    :suboptimal,
    "Map.values/1 → Enum.all?: iterate the map directly as {key, value} pairs"
  )

  smell(
    ~p[Map.values(_) |> Enum.any?(_)],
    :suboptimal,
    "Map.values/1 → Enum.any?: iterate the map directly as {key, value} pairs"
  )

  smell(
    ~p[Map.values(_) |> Enum.find(_)],
    :suboptimal,
    "Map.values/1 → Enum.find: iterate the map directly as {key, value} pairs"
  )

  smell(
    ~p[Map.values(_) |> Enum.filter(_)],
    :suboptimal,
    "Map.values/1 → Enum.filter: iterate the map directly as {key, value} pairs"
  )

  smell(
    ~p[Map.values(_) |> Enum.map(_)],
    :suboptimal,
    "Map.values/1 → Enum.map: iterate the map directly as {key, value} pairs"
  )

  smell(
    from(~p[Enum.count(arg)])
    |> where(not match?({:&, _, _}, ^arg) and not match?({:fn, _, _}, ^arg)),
    :suboptimal,
    "Enum.count/1 without predicate has protocol dispatch overhead; use length/1 for lists"
  )

  smell(
    from(~p[Map.put(_, key, true)]) |> where(not is_atom(^key) and not is_binary(^key)),
    :suboptimal,
    "Map.put/3 with variable key and boolean value suggests membership tracking; use MapSet"
  )

  smell(
    from(~p[Map.put(_, key, false)]) |> where(not is_atom(^key) and not is_binary(^key)),
    :suboptimal,
    "Map.put/3 with variable key and boolean value suggests membership tracking; use MapSet"
  )
end
