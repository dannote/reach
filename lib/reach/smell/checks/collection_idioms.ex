defmodule Reach.Smell.Checks.CollectionIdioms do
  @moduledoc false

  use Reach.Smell.PatternCheck

  smell(
    ~p[Enum.join(_, "")],
    :suboptimal,
    ~S[Enum.join/1 defaults to empty separator; remove the "" argument]
  )

  smell(
    ~p[Enum.take(_, -_)],
    :suboptimal,
    "Enum.take with negative count forces extra traversal; prefer sorting in the desired direction"
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
    ~p[String.replace(_, _, _) |> String.replace(_, _)],
    :suboptimal,
    "chained String.replace/3; use a single String.replace/3 with a regex"
  )
end
