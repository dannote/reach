defmodule Reach.OTP.GenStatem do
  @moduledoc "Extracts gen_statem states, transitions, and event handlers from module IR."

  alias Reach.IR

  @doc """
  Extracts gen_statem state machine information from module IR nodes.

  Returns a map with `:callback_mode`, `:init_state`, `:states`, and `:transitions`.
  Each state has its event handlers. Each transition has source, target,
  event type, and the function node that triggers it.
  """
  @spec analyze([IR.Node.t()]) :: map() | nil
  def analyze(ir_nodes) do
    all_nodes = IR.all_nodes(ir_nodes)
    func_defs = Enum.filter(all_nodes, &(&1.type == :function_def))

    callback_mode = detect_callback_mode(func_defs)
    if callback_mode == nil, do: throw(:not_gen_statem)

    {states, transitions} =
      case callback_mode do
        :state_functions -> analyze_state_functions(func_defs)
        :handle_event_function -> analyze_handle_event_function(func_defs, all_nodes)
      end

    init_state = extract_init_state(func_defs, all_nodes)

    %{
      callback_mode: callback_mode,
      init_state: init_state,
      states: states,
      transitions: transitions
    }
  catch
    :not_gen_statem -> nil
  end

  @doc """
  Detects gen_statem from `@behaviour :gen_statem` or `callback_mode/0`.
  """
  def detect?(all_nodes) do
    has_behaviour_attr?(all_nodes) or has_callback_mode?(all_nodes)
  end

  defp has_behaviour_attr?(all_nodes) do
    Enum.any?(all_nodes, fn node ->
      (node.type == :compiler_directive and node.meta[:directive] == :behaviour and
         match?([%{type: :literal, meta: %{value: :gen_statem}}], node.children)) or
        (node.type == :call and node.meta[:function] == :@ and
           match?(
             [
               %{
                 type: :call,
                 meta: %{function: :behaviour},
                 children: [%{type: :literal, meta: %{value: :gen_statem}}]
               }
             ],
             node.children
           ))
    end)
  end

  defp has_callback_mode?(all_nodes) do
    Enum.any?(all_nodes, fn n ->
      n.type == :function_def and n.meta[:name] == :callback_mode and n.meta[:arity] == 0
    end)
  end

  # --- Callback mode detection ---

  defp detect_callback_mode(func_defs) do
    cm_func = Enum.find(func_defs, &(&1.meta[:name] == :callback_mode and &1.meta[:arity] == 0))

    case cm_func do
      nil ->
        nil

      func ->
        all = IR.all_nodes(func)

        cond do
          has_literal?(all, :state_functions) -> :state_functions
          has_literal?(all, :handle_event_function) -> :handle_event_function
          true -> :state_functions
        end
    end
  end

  defp has_literal?(nodes, value) do
    Enum.any?(nodes, &(&1.type == :literal and &1.meta[:value] == value))
  end

  # --- Init state ---

  defp extract_init_state(func_defs, all_nodes) do
    init = Enum.find(func_defs, &(&1.meta[:name] == :init))
    if init == nil, do: throw(:not_gen_statem)

    attr_values = resolve_module_attributes(all_nodes)

    init
    |> IR.all_nodes()
    |> Enum.flat_map(&extract_init_ok_state(&1, attr_values))
    |> Enum.uniq()
    |> case do
      [single] -> single
      multiple when multiple != [] -> multiple
      [] -> nil
    end
  end

  defp extract_init_ok_state(
         %{type: :tuple, children: [%{type: :literal, meta: %{value: :ok}}, state_node, _ | _]},
         attr_values
       ) do
    case state_node |> extract_state_literal() |> resolve_attr(attr_values) do
      val when is_atom(val) and val != :any -> [val]
      _ -> []
    end
  end

  defp extract_init_ok_state(_, _), do: []

  # --- state_functions mode ---

  @statem_return_tags [:next_state, :keep_state, :stop, :stop_and_reply, :repeat_state]
  @statem_return_atoms [:keep_state_and_data, :repeat_state_and_data, :stop]
  @known_callbacks MapSet.new([:init, :callback_mode, :terminate, :code_change, :format_status])

  defp analyze_state_functions(func_defs) do
    state_funcs =
      func_defs
      |> Enum.filter(fn fd ->
        fd.meta[:name] not in @known_callbacks and
          fd.meta[:arity] == 3 and
          fd.meta[:kind] != :defp and
          has_statem_return?(fd)
      end)
      |> Enum.group_by(& &1.meta[:name])

    states =
      Map.new(state_funcs, fn {state_name, funcs} ->
        events = Enum.flat_map(funcs, &extract_state_func_events/1)
        {state_name, %{events: events}}
      end)

    transitions =
      state_funcs
      |> Enum.flat_map(fn {state_name, funcs} ->
        Enum.flat_map(funcs, &extract_transitions(&1, state_name))
      end)

    {states, transitions}
  end

  defp has_statem_return?(func) do
    func
    |> IR.all_nodes()
    |> Enum.any?(fn node ->
      (node.type == :tuple and
         match?(
           [%{type: :literal, meta: %{value: tag}} | _] when tag in @statem_return_tags,
           node.children
         )) or
        (node.type == :literal and node.meta[:value] in @statem_return_atoms)
    end)
  end

  defp extract_state_func_events(func) do
    func.children
    |> Enum.filter(&(&1.type == :clause))
    |> Enum.map(fn clause ->
      params = Enum.take(clause.children, 3)
      event_type = extract_event_type(Enum.at(params, 0))
      %{event_type: event_type, node: func}
    end)
  end

  # --- handle_event_function mode ---

  defp analyze_handle_event_function(func_defs, all_nodes) do
    he_funcs =
      Enum.filter(func_defs, fn fd ->
        fd.meta[:name] == :handle_event and fd.meta[:arity] == 4
      end)

    attr_values = resolve_module_attributes(all_nodes)

    clauses =
      Enum.flat_map(he_funcs, fn func ->
        func.children
        |> Enum.filter(&(&1.type == :clause))
        |> Enum.map(&{func, &1})
      end)

    state_events =
      clauses
      |> Enum.map(fn {func, clause} ->
        params = Enum.take(clause.children, 4)
        event_type = extract_event_type(Enum.at(params, 0))
        state = extract_state_literal(Enum.at(params, 2)) |> resolve_attr(attr_values)
        {state, event_type, func}
      end)
      |> Enum.group_by(fn {state, _, _} -> state end)

    states =
      Map.new(state_events, fn {state, entries} ->
        events =
          Enum.map(entries, fn {_, event_type, func} ->
            %{event_type: event_type, node: func}
          end)

        {state, %{events: events}}
      end)

    transitions =
      Enum.flat_map(he_funcs, fn func ->
        func.children
        |> Enum.filter(&(&1.type == :clause))
        |> Enum.flat_map(fn clause ->
          params = Enum.take(clause.children, 4)
          state = extract_state_literal(Enum.at(params, 2)) |> resolve_attr(attr_values)
          extract_transitions_from_body(clause, state)
        end)
      end)

    {states, transitions}
  end

  # --- Event type extraction ---

  defp extract_event_type(nil), do: :unknown

  defp extract_event_type(%{type: :literal, meta: %{value: val}}) when is_atom(val), do: val

  defp extract_event_type(%{
         type: :tuple,
         children: [%{type: :literal, meta: %{value: :call}}, _]
       }),
       do: {:call, :from}

  defp extract_event_type(%{
         type: :tuple,
         children: [
           %{type: :literal, meta: %{value: :timeout}},
           %{type: :literal, meta: %{value: name}}
         ]
       }),
       do: {:timeout, name}

  defp extract_event_type(%{type: :var}), do: :any
  defp extract_event_type(_), do: :unknown

  # --- State literal extraction ---

  defp extract_state_literal(nil), do: :any
  defp extract_state_literal(%{type: :literal, meta: %{value: val}}) when is_atom(val), do: val
  defp extract_state_literal(%{type: :var, meta: %{name: :_}}), do: :any
  defp extract_state_literal(%{type: :var}), do: :any

  defp extract_state_literal(%{type: :call, meta: %{function: :@}} = node) do
    case node.children do
      [%{type: :var, meta: %{name: attr_name}}] -> {:module_attribute, attr_name}
      [%{type: :literal, meta: %{value: attr_name}}] -> {:module_attribute, attr_name}
      _ -> :any
    end
  end

  defp extract_state_literal(_), do: :any

  # --- Module attribute resolution ---

  defp resolve_module_attributes(all_nodes) do
    all_nodes
    |> Enum.flat_map(fn
      %{
        type: :call,
        meta: %{function: :@},
        children: [
          %{
            type: :call,
            meta: %{function: name},
            children: [%{type: :literal, meta: %{value: value}}]
          }
        ]
      } ->
        [{name, value}]

      _ ->
        []
    end)
    |> Map.new()
  end

  defp resolve_attr({:module_attribute, name}, attr_values),
    do: Map.get(attr_values, name, {:module_attribute, name})

  defp resolve_attr(other, _), do: other

  # --- Transition extraction ---

  defp extract_transitions(func, from_state) do
    func
    |> IR.all_nodes()
    |> find_next_state_tuples()
    |> Enum.map(fn {to_state, event_type} ->
      %{from: from_state, to: to_state, trigger: event_type, node: func}
    end)
  end

  defp extract_transitions_from_body(clause, from_state) do
    clause
    |> IR.all_nodes()
    |> find_next_state_tuples()
    |> Enum.map(fn {to_state, _} ->
      event_type = extract_event_type(Enum.at(clause.children, 0))
      %{from: from_state || :any, to: to_state, trigger: event_type, node: clause}
    end)
  end

  defp find_next_state_tuples(all_nodes) do
    all_nodes
    |> Enum.filter(fn node ->
      node.type == :tuple and
        match?(
          [%{type: :literal, meta: %{value: :next_state}} | _],
          node.children
        )
    end)
    |> Enum.flat_map(fn tuple ->
      case tuple.children do
        [_, %{type: :literal, meta: %{value: to_state}}, _ | _rest] when is_atom(to_state) ->
          [{to_state, nil}]

        _ ->
          []
      end
    end)
    |> Enum.uniq()
  end
end
