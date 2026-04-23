defmodule Reach.SmellTest do
  use ExUnit.Case, async: true

  describe "Enum.map + List.first detection" do
    test "List.first inside Enum.map callback is a descendant" do
      graph =
        Reach.string_to_graph!("""
        def foo(rows) do
          Enum.map(rows, &List.first/1)
        end
        """)

      all = Reach.nodes(graph)

      map_call =
        Enum.find(
          all,
          &(&1.type == :call and &1.meta[:function] == :map and &1.meta[:module] == Enum)
        )

      first_call =
        Enum.find(
          all,
          &(&1.type == :call and &1.meta[:function] == :first and &1.meta[:module] == List)
        )

      assert map_call
      assert first_call

      descendant_ids = Reach.IR.all_nodes(map_call) |> Enum.map(& &1.id)
      assert first_call.id in descendant_ids
    end

    test "List.first after pipe is NOT a descendant of Enum.map" do
      graph =
        Reach.string_to_graph!("""
        def foo(rows) do
          rows |> Enum.map(&to_string/1) |> List.first()
        end
        """)

      all = Reach.nodes(graph)

      enum_calls =
        all
        |> Enum.filter(fn n ->
          n.type == :call and n.meta[:module] in [Enum, List] and n.source_span != nil
        end)
        |> Enum.sort_by(fn n -> n.source_span[:start_line] end)

      map_call = Enum.find(enum_calls, &(&1.meta[:function] == :map))
      first_call = Enum.find(enum_calls, &(&1.meta[:function] == :first))
      assert map_call && first_call

      descendant_ids = Reach.IR.all_nodes(map_call) |> Enum.map(& &1.id)
      refute first_call.id in descendant_ids
    end
  end

  describe "redundant computation exclusions" do
    test "field access calls are excluded from redundant detection" do
      graph =
        Reach.string_to_graph!("""
        def foo(state) do
          a = state.name
          b = state.name
          {a, b}
        end
        """)

      all = Reach.nodes(graph)

      field_calls =
        Enum.filter(all, fn n ->
          n.type == :call and n.meta[:kind] == :field_access
        end)

      assert length(field_calls) >= 2
    end
  end
end
