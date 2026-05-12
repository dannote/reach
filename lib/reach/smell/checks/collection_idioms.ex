defmodule Reach.Smell.Checks.CollectionIdioms do
  @moduledoc "Pattern-based detection of suboptimal collection operations."

  use Reach.Smell.PatternCheck

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
    ~p[Integer.to_string(_) |> String.graphemes()],
    :suboptimal,
    "Integer.to_string/1 → String.graphemes/1; prefer Integer.digits/1"
  )

  smell(
    ~p[Integer.to_string(_, _) |> String.graphemes()],
    :suboptimal,
    "Integer.to_string/2 → String.graphemes/1; prefer Integer.digits/2"
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
    ~p[Map.keys(_) |> Enum.join()],
    :suboptimal,
    "Map.keys/1 → Enum.join: iterate the map directly or map_join key/value pairs"
  )

  smell(
    ~p[Map.keys(_) |> Enum.join(_)],
    :suboptimal,
    "Map.keys/1 → Enum.join: iterate the map directly or map_join key/value pairs"
  )

  smell(
    ~p[Map.keys(_) |> Enum.uniq()],
    :suboptimal,
    "Map.keys/1 returns unique keys already; Enum.uniq/1 is redundant"
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
    ~p[Map.values(_) |> Enum.join()],
    :suboptimal,
    "Map.values/1 → Enum.join: iterate the map directly or map_join key/value pairs"
  )

  smell(
    ~p[Map.values(_) |> Enum.join(_)],
    :suboptimal,
    "Map.values/1 → Enum.join: iterate the map directly or map_join key/value pairs"
  )

  smell(
    ~p[Map.values(_) |> Enum.sum()],
    :suboptimal,
    "Map.values/1 → Enum.sum: iterate the map directly with Enum.reduce/3"
  )

  smell(
    ~p[Map.values(_) |> Enum.max()],
    :suboptimal,
    "Map.values/1 → Enum.max: iterate the map directly with Enum.max_by/2"
  )

  smell(
    ~p[Map.values(_) |> Enum.min()],
    :suboptimal,
    "Map.values/1 → Enum.min: iterate the map directly with Enum.min_by/2"
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

  # length(list) == 0 → list == []
  smell(
    ~p[length(_) == 0],
    :suboptimal,
    "length/1 == 0 is O(n); use pattern match or == []"
  )

  smell(
    ~p[0 == length(_)],
    :suboptimal,
    "length/1 == 0 is O(n); use pattern match or == []"
  )

  # length(list) > 0 → list != [] or match?([_|_], list)
  smell(
    ~p[length(_) > 0],
    :suboptimal,
    "length/1 > 0 is O(n); use != [] or match?([_ | _], list)"
  )

  smell(
    from(~p[Regex.replace(_, _, _)]) |> where(piped()),
    :suboptimal,
    "Regex.replace/3 in a pipe receives the piped string as the regex argument; use String.replace/3"
  )

  smell(
    from(~p[Regex.replace(_, _, _, _)]) |> where(piped()),
    :suboptimal,
    "Regex.replace/4 in a pipe receives the piped string as the regex argument; use String.replace/4"
  )

  smell(
    ~p[length(String.split(_, _)) - 1],
    :suboptimal,
    "length(String.split) - 1 allocates the full split list just to count; use :binary.matches/2 |> length/1"
  )

  smell(
    ~p[Map.keys(_) |> Enum.member?(_)],
    :suboptimal,
    "Map.keys/1 → Enum.member?: use Map.has_key?/2 directly"
  )

  smell(
    ~p[Map.values(_) |> Enum.count()],
    :suboptimal,
    "Map.values/1 → Enum.count: use map_size/1 instead"
  )

  smell(
    ~p[Map.keys(_) |> Enum.count()],
    :suboptimal,
    "Map.keys/1 → Enum.count: use map_size/1 instead"
  )

  smell(
    ~p[Map.keys(_) |> length()],
    :suboptimal,
    "Map.keys/1 → length: use map_size/1 instead"
  )

  smell(
    ~p[Map.values(_) |> length()],
    :suboptimal,
    "Map.values/1 → length: use map_size/1 instead"
  )

  smell(
    ~p[Enum.at(_, -1)],
    :suboptimal,
    "Enum.at(list, -1) traverses the list twice; use List.last/1"
  )

  smell(
    ~p[if left > right, do: left, else: right],
    :suboptimal,
    "if a > b, do: a, else: b reimplements max/2; use Kernel.max/2"
  )

  smell(
    ~p[if left >= right, do: left, else: right],
    :suboptimal,
    "if a >= b, do: a, else: b reimplements max/2; use Kernel.max/2"
  )

  smell(
    ~p[if left < right, do: left, else: right],
    :suboptimal,
    "if a < b, do: a, else: b reimplements min/2; use Kernel.min/2"
  )

  smell(
    ~p[if left <= right, do: left, else: right],
    :suboptimal,
    "if a <= b, do: a, else: b reimplements min/2; use Kernel.min/2"
  )

  smell(
    ~p[Enum.map(_, _) |> Enum.into(%{})],
    :suboptimal,
    "Enum.map/2 |> Enum.into(%{}): use Map.new/2"
  )

  smell(
    ~p[Enum.into(_, MapSet.new())],
    :suboptimal,
    "Enum.into(enum, MapSet.new()): use MapSet.new/1"
  )

  smell(
    ~p[Enum.map(_, _) |> Enum.concat()],
    :eager_pattern,
    "Enum.map/2 |> Enum.concat/1: use Enum.flat_map/2"
  )

  smell(
    from(~p[Enum.into(_, target)])
    |> where(match?({:%{}, _, []}, ^target)),
    :suboptimal,
    "Enum.into(enum, %{}): use Map.new/1"
  )

  smell(
    ~p[if _, do: true, else: false],
    :suboptimal,
    "if condition, do: true, else: false: the condition is already a boolean"
  )

  smell(
    ~p[if _, do: false, else: true],
    :suboptimal,
    "if condition, do: false, else: true: use not/!/1 or negate the condition"
  )
end
