defmodule ToolCall.TypeExpr.Projection do
  @moduledoc """
  Exact set operations on `ToolCall.TypeExpr`, used to lower intersections and
  negations before they reach `ToolCall.IR.Type`.

  JSON Schema cannot carry an arbitrary intersection or complement, so each
  operation either returns a value that is *exactly* the intersection (or
  difference) or reports `:error`. A caller that receives `:error` must degrade
  explicitly rather than approximate the type — silently widening to `anyOf` or
  `any` would tell the model the wrong contract.

  Supported exactly today:

    * `:any` and `:none` identities
    * integer ranges and `integer()`, including disjoint ranges (an empty
      intersection, and a difference that splits into at most two ranges)
    * `{:literal, value}` against literals and enums
    * enums against enums
    * maps whose fields and additional properties can be merged
    * identical nodes
  """

  alias ToolCall.TypeExpr

  @type result :: {:ok, TypeExpr.t()} | :error

  @doc """
  Intersects two type expressions.

  A `{:negation, inner}` operand is handled as a difference, so
  `atom() and not nil` lowers without ever emitting a JSON Schema `not`.
  """
  @spec intersect(TypeExpr.t(), TypeExpr.t()) :: result()
  def intersect({:negation, inner}, right), do: subtract(right, inner)
  def intersect(left, {:negation, inner}), do: subtract(left, inner)

  def intersect(left, right) when left == right, do: {:ok, left}
  def intersect(:any, right), do: {:ok, right}
  def intersect(left, :any), do: {:ok, left}
  def intersect(:none, _right), do: {:ok, :none}
  def intersect(_left, :none), do: {:ok, :none}

  def intersect({:annotated, type, metadata}, right) do
    case intersect(type, right) do
      {:ok, result} -> {:ok, {:annotated, result, metadata}}
      :error -> :error
    end
  end

  def intersect(left, {:annotated, type, _metadata}), do: intersect(left, type)

  def intersect({:primitive, :number}, {:integer_range, _low, _high} = range),
    do: {:ok, range}

  def intersect({:integer_range, _low, _high} = range, {:primitive, :number}),
    do: {:ok, range}

  def intersect({:primitive, :number}, {:primitive, :integer}), do: {:ok, {:primitive, :integer}}
  def intersect({:primitive, :integer}, {:primitive, :number}), do: {:ok, {:primitive, :integer}}

  def intersect({:primitive, :number}, {:primitive, :float}), do: {:ok, {:primitive, :float}}
  def intersect({:primitive, :float}, {:primitive, :number}), do: {:ok, {:primitive, :float}}

  def intersect({:primitive, kind}, {:literal, value}) when is_atom(kind),
    do: intersect_literal(value, {:primitive, kind})

  def intersect({:primitive, :string}, {:string, metadata}), do: {:ok, {:string, metadata}}
  def intersect({:string, metadata}, {:primitive, :string}), do: {:ok, {:string, metadata}}

  def intersect({:primitive, :integer}, right), do: intersect_integer(nil, nil, right)
  def intersect(left, {:primitive, :integer}), do: intersect_integer(nil, nil, left)

  def intersect({:integer_range, low, high}, right), do: intersect_integer(low, high, right)
  def intersect(left, {:integer_range, low, high}), do: intersect_integer(low, high, left)

  def intersect({:literal, value}, right), do: intersect_literal(value, right)
  def intersect(left, {:literal, value}), do: intersect_literal(value, left)

  def intersect({:enum, left_values}, {:enum, right_values})
      when is_list(left_values) and is_list(right_values),
      do: {:ok, enum(Enum.filter(left_values, &(&1 in right_values)))}

  def intersect({:enum, values}, {:primitive, kind}) when is_list(values),
    do: intersect_enum_primitive(values, kind)

  def intersect({:primitive, kind}, {:enum, values}) when is_list(values),
    do: intersect_enum_primitive(values, kind)

  def intersect({:union, variants}, right), do: intersect_union(variants, right)
  def intersect(left, {:union, variants}), do: intersect_union(variants, left)

  def intersect({:map, left_fields, left_additional}, {:map, right_fields, right_additional}) do
    intersect_maps(left_fields, left_additional, right_fields, right_additional)
  end

  # An unconstrained tuple constrains nothing, so the other side survives.
  def intersect({:tuple, nil}, right), do: union_fixed_tuple(right)
  def intersect(left, {:tuple, nil}), do: union_fixed_tuple(left)

  def intersect({:tuple, left_items}, {:tuple, right_items})
      when is_list(left_items) and is_list(right_items) do
    if length(left_items) == length(right_items) do
      intersect_tuples(left_items, right_items)
    else
      {:ok, :none}
    end
  end

  def intersect({:ref, name}, {:ref, name}), do: {:ok, {:ref, name}}

  def intersect({:string, left}, {:string, right}), do: intersect_strings(left, right)

  def intersect({:remote, module, function, left_args}, {:remote, module, function, right_args}) do
    if left_args == right_args, do: {:ok, {:remote, module, function, left_args}}, else: :error
  end

  def intersect(_left, _right), do: :error

  @doc """
  Subtracts `right` from `left`, producing the type of values in `left` that are
  not in `right`.
  """
  @spec subtract(TypeExpr.t(), TypeExpr.t()) :: result()
  def subtract(left, :none), do: {:ok, left}
  def subtract(:none, _right), do: {:ok, :none}
  def subtract(left, right) when left == right, do: {:ok, :none}

  def subtract(left, {:union, variants}) when is_list(variants) do
    variants
    |> Enum.reduce_while({:ok, left}, fn variant, {:ok, acc} ->
      case subtract(acc, variant) do
        {:ok, :none} -> {:halt, {:ok, :none}}
        {:ok, result} -> {:cont, {:ok, result}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, result} -> {:ok, union([result])}
      :error -> :error
    end
  end

  def subtract({:annotated, type, metadata}, right) do
    case subtract(type, right) do
      {:ok, result} -> {:ok, {:annotated, result, metadata}}
      :error -> :error
    end
  end

  def subtract({:integer_range, low, high}, right),
    do: subtract_integer(low, high, right)

  def subtract({:primitive, :integer}, right), do: subtract_integer(nil, nil, right)

  def subtract({:literal, value}, right), do: subtract_literal(value, right)

  def subtract({:enum, values}, {:literal, value}) when is_list(values),
    do: reject_value(value, values)

  def subtract({:enum, values}, {:primitive, kind}) when is_list(values) do
    kept = Enum.reject(values, &literal_of_kind?(&1, kind))
    {:ok, enum(kept)}
  end

  def subtract({:enum, values}, {:enum, removed}) when is_list(values) and is_list(removed) do
    case Enum.reject(values, &(&1 in removed)) do
      [] -> {:ok, :none}
      [single] -> {:ok, {:literal, single}}
      rest -> {:ok, {:enum, rest}}
    end
  end

  def subtract({:union, variants}, right) do
    variants
    |> Enum.reduce_while({:ok, []}, fn variant, {:ok, acc} ->
      case subtract(variant, right) do
        {:ok, :none} -> {:cont, {:ok, acc}}
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, union(Enum.reverse(results))}
      :error -> :error
    end
  end

  def subtract(_left, _right), do: :error

  defp intersect_integer(low, high, {:integer_range, right_low, right_high}) do
    integer_range(lower_bound(low, right_low), upper_bound(high, right_high))
  end

  defp intersect_integer(low, high, {:literal, value}) when is_integer(value) do
    if in_range?(value, low, high), do: {:ok, {:literal, value}}, else: {:ok, :none}
  end

  defp intersect_integer(_low, _high, {:literal, _value}), do: {:ok, :none}

  defp intersect_integer(low, high, {:enum, values}) when is_list(values) do
    kept = Enum.filter(values, &(is_integer(&1) and in_range?(&1, low, high)))

    case kept do
      [] -> {:ok, :none}
      values -> {:ok, {:enum, values}}
    end
  end

  defp intersect_integer(low, high, {:primitive, :integer}), do: integer_range(low, high)

  defp intersect_integer(_low, _high, {:primitive, kind}) when kind not in [:integer, :number],
    do: {:ok, :none}

  defp intersect_integer(_low, _high, _right), do: :error

  defp intersect_enum_primitive(values, kind) do
    kept = Enum.filter(values, &literal_of_kind?(&1, kind))
    {:ok, enum(kept)}
  end

  defp literal_of_kind?(value, :string) when is_binary(value), do: true
  defp literal_of_kind?(value, :atom) when is_atom(value), do: true
  defp literal_of_kind?(value, :boolean) when is_boolean(value), do: true
  defp literal_of_kind?(value, :integer) when is_integer(value), do: true
  defp literal_of_kind?(value, :number) when is_number(value), do: true
  defp literal_of_kind?(_value, _kind), do: false

  defp intersect_literal(value, {:literal, value}), do: {:ok, {:literal, value}}
  defp intersect_literal(_value, {:literal, _other}), do: {:ok, :none}

  defp intersect_literal(value, {:enum, values}) do
    if value in values, do: {:ok, {:literal, value}}, else: {:ok, :none}
  end

  defp intersect_literal(value, {:primitive, kind}), do: literal_kind(value, kind)
  defp intersect_literal(_value, _right), do: :error

  # A literal and a primitive are either disjoint or the literal itself; the
  # schema must not keep the wider primitive.
  defp literal_kind(value, :string) when is_binary(value), do: {:ok, {:literal, value}}
  defp literal_kind(value, :atom) when is_atom(value), do: {:ok, {:literal, value}}
  defp literal_kind(value, :boolean) when is_boolean(value), do: {:ok, {:literal, value}}
  defp literal_kind(value, :integer) when is_integer(value), do: {:ok, {:literal, value}}

  defp literal_kind(value, :number) when is_number(value), do: {:ok, {:literal, value}}
  defp literal_kind(_value, _kind), do: {:ok, :none}

  defp intersect_union(variants, right) do
    variants
    |> Enum.reduce_while({:ok, []}, fn variant, {:ok, acc} ->
      case intersect(variant, right) do
        {:ok, :none} -> {:cont, {:ok, acc}}
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, union(Enum.reverse(results))}
      :error -> :error
    end
  end

  defp intersect_maps(left_fields, left_additional, right_fields, right_additional) do
    left = Map.new(left_fields, fn {key, type, required?} -> {key, {type, required?}} end)
    right = Map.new(right_fields, fn {key, type, required?} -> {key, {type, required?}} end)

    keys = Enum.uniq(Enum.map(left_fields, &elem(&1, 0)) ++ Enum.map(right_fields, &elem(&1, 0)))

    case intersect_fields(keys, left, left_additional, right, right_additional) do
      {:ok, :none} ->
        {:ok, :none}

      {:ok, fields} ->
        case intersect_additional(left_additional, right_additional) do
          {:ok, :none} -> {:ok, {:map, fields, nil}}
          {:ok, additional} -> {:ok, {:map, fields, additional}}
          :error -> :error
        end

      :error ->
        :error
    end
  end

  defp union_fixed_tuple({:tuple, items} = node) when is_list(items), do: {:ok, node}
  defp union_fixed_tuple({:tuple, nil} = node), do: {:ok, node}
  defp union_fixed_tuple(_other), do: :error

  defp intersect_tuples(left_items, right_items) do
    left_items
    |> Enum.zip(right_items)
    |> Enum.reduce_while({:ok, []}, fn {left, right}, {:ok, acc} ->
      case intersect(left, right) do
        {:ok, :none} -> {:halt, {:ok, :none}}
        {:ok, type} -> {:cont, {:ok, [type | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, items} when is_list(items) -> {:ok, {:tuple, Enum.reverse(items)}}
      other -> other
    end
  end

  # A string constraint narrows the other side. Two different patterns or
  # formats cannot be intersected exactly, so they fall back to `:error` rather
  # than keeping one and dropping the other.
  defp intersect_strings(left, right) do
    with {:ok, pattern} <- narrower(left, right, :pattern),
         {:ok, format} <- narrower(left, right, :format),
         {:ok, source} <- narrower(left, right, :source) do
      metadata =
        %{}
        |> put_present(:pattern, pattern)
        |> put_present(:format, format)
        |> put_present(:source, source)

      {:ok, {:string, metadata}}
    end
  end

  defp narrower(left, right, key) do
    case {Map.get(left, key), Map.get(right, key)} do
      {nil, value} -> {:ok, value}
      {value, nil} -> {:ok, value}
      {same, same} -> {:ok, same}
      {_left, _right} -> :error
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # Maps are records with optional/open keys. A key that one side forbids (a
  # closed map without that field) cannot be introduced by the other side; a
  # required key that becomes forbidden makes the whole intersection empty.
  defp intersect_fields(keys, left, left_additional, right, right_additional) do
    keys
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn key, {:ok, acc} ->
      case intersect_field(key, left, left_additional, right, right_additional) do
        {:ok, :none} -> {:halt, {:ok, :none}}
        {:ok, :absent} -> {:cont, {:ok, acc}}
        {:ok, field} -> {:cont, {:ok, [field | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> finish_fields()
  end

  defp intersect_field(key, left, left_additional, right, right_additional) do
    case {
      side_constraint(left, left_additional, key),
      side_constraint(right, right_additional, key)
    } do
      {:forbidden, {:field, _type, true}} ->
        {:ok, :none}

      {{:field, _type, true}, :forbidden} ->
        {:ok, :none}

      {:forbidden, _other} ->
        {:ok, :absent}

      {_other, :forbidden} ->
        {:ok, :absent}

      {{:field, left_type, left_required?}, {:field, right_type, right_required?}} ->
        intersect_field_types(key, left_type, right_type, left_required?, right_required?)

      {{:field, left_type, left_required?}, {:additional, right_type}} ->
        intersect_field_types(key, left_type, right_type, left_required?, false)

      {{:additional, left_type}, {:field, right_type, right_required?}} ->
        intersect_field_types(key, left_type, right_type, false, right_required?)

      {{:additional, left_type}, {:additional, right_type}} ->
        intersect_field_types(key, left_type, right_type, false, false)
    end
  end

  defp side_constraint(fields, additional, key) do
    case Map.fetch(fields, key) do
      {:ok, {type, required?}} ->
        {:field, type, required?}

      :error when additional in [nil, :none] ->
        :forbidden

      :error ->
        {:additional, additional}
    end
  end

  defp intersect_field_types(key, left_type, right_type, left_required?, right_required?) do
    case intersect(left_type, right_type) do
      {:ok, :none} when left_required? or right_required? ->
        {:ok, :none}

      {:ok, :none} ->
        {:ok, :absent}

      {:ok, type} ->
        {:ok, {key, type, left_required? or right_required?}}

      :error ->
        :error
    end
  end

  defp finish_fields({:ok, :none}), do: {:ok, :none}
  defp finish_fields({:ok, fields}), do: {:ok, Enum.reverse(fields)}
  defp finish_fields(:error), do: :error

  # A closed object forbids extra keys, so intersecting it with an open object
  # keeps it closed. Widening to the other side's `additionalProperties` would
  # let the model send keys the closed side rejects.
  defp intersect_additional(nil, _additional), do: {:ok, nil}
  defp intersect_additional(_additional, nil), do: {:ok, nil}

  defp intersect_additional(left, right), do: intersect(left, right)

  defp subtract_integer(_low, _high, {:primitive, :integer}), do: {:ok, :none}
  defp subtract_integer(_low, _high, {:primitive, :number}), do: {:ok, :none}

  defp subtract_integer(low, high, {:integer_range, right_low, right_high}) do
    left_low = low || :neg_infinity
    left_high = high || :infinity
    right_low = right_low || :neg_infinity
    right_high = right_high || :infinity

    if disjoint_ranges?(left_low, left_high, right_low, right_high) do
      {:ok, {:integer_range, low, high}}
    else
      [
        {left_low, decrement(right_low)},
        {increment(right_high), left_high}
      ]
      |> Enum.filter(&range_valid?/1)
      |> remaining_ranges()
    end
  end

  defp subtract_integer(_low, _high, _right), do: :error

  defp remaining_ranges([]), do: {:ok, :none}

  defp remaining_ranges([{from, to}]),
    do: integer_range(normalize_bound(from), normalize_bound(to))

  defp remaining_ranges(ranges), do: {:ok, union(Enum.map(ranges, &range_node/1))}

  defp subtract_literal(value, {:literal, value}), do: {:ok, :none}
  defp subtract_literal(value, {:enum, values}), do: reject_value(value, values)

  defp subtract_literal(value, {:integer_range, low, high}) when is_integer(value) do
    if in_range?(value, low, high), do: {:ok, :none}, else: {:ok, {:literal, value}}
  end

  defp subtract_literal(_value, _right), do: :error

  defp reject_value(value, values), do: {:ok, enum(Enum.reject(values, &(&1 == value)))}

  defp union(items) do
    items
    |> Enum.flat_map(fn
      {:union, nested} -> nested
      item -> [item]
    end)
    |> Enum.reject(&(&1 == :none))
    |> Enum.uniq()
    |> enum_or_union()
  end

  defp enum_or_union([]), do: :none
  defp enum_or_union([single]), do: single
  defp enum_or_union(items), do: {:union, items}

  defp enum([]), do: :none
  defp enum([single]), do: {:literal, single}
  defp enum(values), do: {:enum, values}

  defp range_node({from, to}) do
    case {normalize_bound(from), normalize_bound(to)} do
      {nil, nil} -> {:primitive, :integer}
      {from, to} -> {:integer_range, from, to}
    end
  end

  defp integer_range(nil, nil), do: {:ok, {:primitive, :integer}}

  defp integer_range(low, high) do
    if is_integer(low) and is_integer(high) and low > high,
      do: {:ok, :none},
      else: {:ok, {:integer_range, low, high}}
  end

  defp in_range?(_value, nil, nil), do: true
  defp in_range?(value, low, nil), do: value >= low
  defp in_range?(value, nil, high), do: value <= high
  defp in_range?(value, low, high), do: value >= low and value <= high

  defp lower_bound(nil, other), do: other
  defp lower_bound(other, nil), do: other
  defp lower_bound(left, right), do: max(left, right)

  defp upper_bound(nil, other), do: other
  defp upper_bound(other, nil), do: other
  defp upper_bound(left, right), do: min(left, right)

  defp disjoint_ranges?(left_low, left_high, right_low, right_high) do
    below?(left_high, right_low) or above?(left_low, right_high)
  end

  defp below?(:infinity, _right_low), do: false
  defp below?(_left_high, :neg_infinity), do: false

  defp below?(left_high, right_low) when is_integer(left_high) and is_integer(right_low),
    do: left_high < right_low

  defp below?(_left_high, _right_low), do: false

  defp above?(_left_low, :infinity), do: false
  defp above?(:neg_infinity, _right_high), do: false

  defp above?(left_low, right_high) when is_integer(left_low) and is_integer(right_high),
    do: left_low > right_high

  defp above?(_left_low, _right_high), do: false

  defp decrement(:neg_infinity), do: :neg_infinity
  defp decrement(:infinity), do: :infinity
  defp decrement(value) when is_integer(value), do: value - 1

  defp increment(:neg_infinity), do: :neg_infinity
  defp increment(:infinity), do: :infinity
  defp increment(value) when is_integer(value), do: value + 1

  defp range_valid?({from, to}) do
    cond do
      from == :infinity -> false
      to == :neg_infinity -> false
      is_integer(from) and is_integer(to) -> from <= to
      true -> true
    end
  end

  defp normalize_bound(:neg_infinity), do: nil
  defp normalize_bound(:infinity), do: nil
  defp normalize_bound(value), do: value
end
