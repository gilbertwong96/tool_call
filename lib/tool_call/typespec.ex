defmodule ToolCall.Typespec do
  @moduledoc """
  Converts a quoted typespec AST (aliases already expanded) into `ToolCall.IR.Type`.

  This module is deliberately total: unknown shapes degrade to `:any` rather
  than raising, so that adding a new typespec construct to a codebase never
  breaks compilation of unrelated tools.
  """

  alias ToolCall.IR.{Field, Type}

  @unrepresentable [:fun, :pid, :port, :reference, :mfa, :no_return, :none]

  alias ToolCall.Patterns

  @doc """
  Maps a quoted type to an `ToolCall.IR.Type`.

  Aliases must already be expanded (`Macro.expand/2`), otherwise remote types
  such as `String.t()` arrive as `{:__aliases__, ...}` and degrade to `:any`.
  """
  @spec to_type(term()) :: Type.t()
  def to_type(ast)

  # --- literals -------------------------------------------------------------

  def to_type(nil), do: %Type{kind: :null, source: nil}
  def to_type(true), do: %Type{kind: :enum, values: [true], source: true}
  def to_type(false), do: %Type{kind: :enum, values: [false], source: false}

  def to_type(atom) when is_atom(atom) and atom not in [nil, true, false] do
    %Type{kind: :enum, values: [atom], source: atom}
  end

  def to_type(int) when is_integer(int) do
    %Type{kind: :integer, minimum: int, maximum: int, source: int}
  end

  def to_type(float) when is_float(float) do
    %Type{kind: :float, source: float}
  end

  def to_type({:-, _, [number]}) when is_number(number), do: to_type(-number)

  # --- compound forms -------------------------------------------------------

  def to_type({:|, _, [left, right]}) do
    [left, right]
    |> Enum.flat_map(&flatten_union/1)
    |> build_union()
  end

  def to_type({:.., _, [low, high]}) do
    case {int_literal(low), int_literal(high)} do
      {{:ok, low}, {:ok, high}} -> %Type{kind: :integer, minimum: low, maximum: high}
      _ -> local(:.., [low, high])
    end
  end

  def to_type({:%{}, _, pairs}), do: build_object(pairs)

  def to_type({:{}, _, elements}) do
    %Type{kind: :tuple, items: Enum.map(elements, &to_type/1)}
  end

  def to_type({left, right}), do: %Type{kind: :tuple, items: [to_type(left), to_type(right)]}

  # `[t]` is a one-element list in the AST; `[]` is an empty list literal.
  def to_type([{:->, _, _}]), do: %Type{kind: :unsupported, source: :fun}
  def to_type([type]), do: %Type{kind: :array, items: to_type(type)}
  def to_type([]), do: %Type{kind: :array, items: %Type{kind: :any}}

  # Remote types, e.g. String.t() or Date.t()
  def to_type({{:., _, [module, function]}, _, args}) when is_atom(module) do
    remote(module, function, args)
  end

  # Local type calls, e.g. integer() or keyword(String.t())
  def to_type({name, _, args}) when is_atom(name) and is_list(args) do
    local(name, args)
  end

  def to_type(other), do: %Type{kind: :any, source: other}

  # --- local types ----------------------------------------------------------

  defp local(:integer, []), do: %Type{kind: :integer}
  defp local(:non_neg_integer, []), do: %Type{kind: :integer, minimum: 0}
  defp local(:pos_integer, []), do: %Type{kind: :integer, minimum: 1}
  defp local(:neg_integer, []), do: %Type{kind: :integer, maximum: -1}
  defp local(:byte, []), do: %Type{kind: :integer, minimum: 0, maximum: 255}
  defp local(:float, []), do: %Type{kind: :float}
  defp local(:number, []), do: %Type{kind: :number}

  defp local(:atom, []), do: %Type{kind: :atom}
  defp local(:module, []), do: %Type{kind: :atom}
  defp local(:boolean, []), do: %Type{kind: :boolean}

  defp local(:binary, []), do: %Type{kind: :string, source: :binary}
  defp local(:bitstring, []), do: %Type{kind: :string, source: :bitstring}
  defp local(:string, []), do: %Type{kind: :string, source: :string}
  defp local(:charlist, []), do: %Type{kind: :string, source: :charlist}
  defp local(:char, []), do: %Type{kind: :string, pattern: Patterns.char(), source: :char}

  defp local(:list, []), do: %Type{kind: :array, items: %Type{kind: :any}}
  defp local(:list, [type]), do: %Type{kind: :array, items: to_type(type)}

  defp local(:nonempty_list, []), do: %Type{kind: :array, items: %Type{kind: :any}, minimum: 1}
  defp local(:nonempty_list, [type]), do: %Type{kind: :array, items: to_type(type), minimum: 1}

  defp local(:keyword, args) do
    case args do
      [] ->
        %Type{kind: :object, fields: [], additional: %Type{kind: :any}, source: :keyword}

      [type] ->
        %Type{kind: :object, fields: [], additional: to_type(type), source: :keyword}

      other ->
        %Type{kind: :any, source: {:keyword, other}}
    end
  end

  defp local(:map, []), do: %Type{kind: :object, fields: [], additional: %Type{kind: :any}}
  defp local(:tuple, []), do: %Type{kind: :array, items: %Type{kind: :any}}

  defp local(:as_boolean, [type]), do: to_type(type)
  defp local(:as_boolean, []), do: %Type{kind: :boolean}

  defp local(name, []) when name in [:term, :any], do: %Type{kind: :any, source: name}
  defp local(name, []) when name in @unrepresentable, do: %Type{kind: :unsupported, source: name}

  defp local(:struct, []), do: %Type{kind: :object, fields: [], additional: %Type{kind: :any}}

  defp local(name, args) do
    %Type{kind: :any, source: {name, args}}
  end

  # --- remote types ---------------------------------------------------------

  defp remote(String, _fun, _args), do: %Type{kind: :string, source: {String, :t}}
  defp remote(Keyword, _fun, args), do: local(:keyword, args)
  defp remote(Path, _fun, _args), do: %Type{kind: :string, source: {Path, :t}}

  defp remote(module, _fun, _args) when module in [Date, Time, DateTime, NaiveDateTime] do
    %Type{kind: :string, source: {module, :t}}
  end

  defp remote(Decimal, _fun, _args) do
    %Type{kind: :string, source: {Decimal, :t}, pattern: Patterns.decimal()}
  end

  defp remote(module, function, args) do
    %Type{kind: :any, source: {module, function, args}}
  end

  @doc """
  True when the tree contains a domain JSON cannot represent at all.

  `:any` is not unrepresentable: it means "unknown", and JSON can carry any
  value for it. Only `:unsupported` (functions, pids, refs) is.
  """
  @spec unrepresentable?(Type.t()) :: boolean()
  def unrepresentable?(%Type{kind: kind}) when kind in [:unsupported], do: true
  def unrepresentable?(%Type{kind: :array, items: items}), do: unrepresentable?(items)

  def unrepresentable?(%Type{kind: :tuple, items: items}),
    do: Enum.any?(items || [], &unrepresentable?/1)

  def unrepresentable?(%Type{kind: :union, variants: variants}),
    do: Enum.any?(variants || [], &unrepresentable?/1)

  def unrepresentable?(%Type{kind: :object, fields: fields, additional: additional}) do
    Enum.any?(fields || [], &unrepresentable?(&1.type)) or unrepresentable?(additional)
  end

  def unrepresentable?(nil), do: false
  def unrepresentable?(%Type{}), do: false

  @doc """
  True when the tree contains an object whose keys the spec does not fix.

  Strict mode closes every object with `additionalProperties: false`, so an open
  one reaches the model as an object that accepts no key at all.
  """
  @spec open_object?(Type.t() | nil) :: boolean()
  def open_object?(%Type{kind: :object} = type) do
    not is_nil(type.additional) or Enum.any?(type.fields || [], &open_object?(&1.type))
  end

  def open_object?(%Type{kind: :array, items: items}), do: open_object?(items)
  def open_object?(%Type{kind: :tuple, items: items}), do: Enum.any?(items || [], &open_object?/1)

  def open_object?(%Type{kind: :union, variants: variants}),
    do: Enum.any?(variants || [], &open_object?/1)

  def open_object?(_type), do: false

  @doc """
  True when the tree contains a tuple, which strict mode cannot express.

  OpenAI rejects `prefixItems`, so the emitter can only keep the arity.
  """
  @spec tuple?(Type.t() | nil) :: boolean()
  def tuple?(%Type{kind: :tuple}), do: true
  def tuple?(%Type{kind: :array, items: items}), do: tuple?(items)
  def tuple?(%Type{kind: :union, variants: variants}), do: Enum.any?(variants || [], &tuple?/1)

  def tuple?(%Type{kind: :object} = type),
    do: Enum.any?(type.fields || [], &tuple?(&1.type)) or tuple?(type.additional)

  def tuple?(_type), do: false

  @doc """
  True when the declared type is handed to the function as its wire value.

  `Decimal.t()` is the only case: it travels as a decimal string, and building a
  `%Decimal{}` would need the `decimal` package, which this library does not
  depend on.
  """
  @spec wire_only?(Type.t() | nil) :: boolean()
  def wire_only?(%Type{kind: :string, source: {Decimal, :t}}), do: true
  def wire_only?(%Type{kind: :array, items: items}), do: wire_only?(items)
  def wire_only?(%Type{kind: :tuple, items: items}), do: Enum.any?(items || [], &wire_only?/1)

  def wire_only?(%Type{kind: :union, variants: variants}),
    do: Enum.any?(variants || [], &wire_only?/1)

  def wire_only?(%Type{kind: :object} = type),
    do: Enum.any?(type.fields || [], &wire_only?(&1.type)) or wire_only?(type.additional)

  def wire_only?(_type), do: false

  @doc """
  True when the tree has no JSON type the model can constrain against.

  This is broader than `unrepresentable?/1`: `:any` and open objects do have a
  JSON encoding, but they cannot be typed in the strict schema subset.
  """
  @spec untyped?(Type.t() | nil) :: boolean()
  def untyped?(%Type{kind: kind}) when kind in [:any, :unsupported], do: true
  def untyped?(%Type{kind: :array, items: items}), do: untyped?(items)
  def untyped?(%Type{kind: :tuple, items: items}), do: Enum.any?(items || [], &untyped?/1)

  def untyped?(%Type{kind: :union, variants: variants}),
    do: Enum.any?(variants || [], &untyped?/1)

  def untyped?(%Type{kind: :object} = type) do
    Enum.any?(type.fields || [], &untyped?(&1.type)) or untyped?(type.additional)
  end

  def untyped?(nil), do: false
  def untyped?(%Type{}), do: false

  # --- helpers --------------------------------------------------------------

  defp int_literal(int) when is_integer(int), do: {:ok, int}
  defp int_literal({:-, _, [int]}) when is_integer(int), do: {:ok, -int}
  defp int_literal(_other), do: :error

  defp flatten_union({:|, _, [left, right]}), do: flatten_union(left) ++ flatten_union(right)
  defp flatten_union(other), do: [to_type(other)]

  defp build_union(variants) do
    {nulls, rest} = Enum.split_with(variants, &(&1.kind == :null))
    {singletons, rest} = Enum.split_with(rest, &singleton?/1)
    nullable? = nulls != []

    cond do
      rest == [] and singletons != [] -> union_enum(singletons, nullable?)
      singletons == [] and match?([_], rest) -> union_single(rest, nullable?)
      singletons == [] and same_kind?(rest) -> union_merged(rest, nullable?)
      true -> union_mixed(rest, singletons, nullable?)
    end
  end

  defp union_enum(singletons, nullable?) do
    %Type{kind: :enum, values: Enum.map(singletons, &singleton_value/1), nullable: nullable?}
  end

  defp union_single([type], nullable?) do
    %{type | nullable: nullable? or type.nullable}
  end

  defp union_merged(rest, nullable?) do
    case merge_same_kind_list(rest) do
      {:ok, merged} -> %{merged | nullable: nullable? or merged.nullable}
      :error -> union_mixed(rest, [], nullable?)
    end
  end

  defp union_mixed(rest, singletons, nullable?) do
    variants = if singletons == [], do: rest, else: rest ++ [union_enum(singletons, false)]
    %Type{kind: :union, variants: Enum.uniq_by(variants, &signature/1), nullable: nullable?}
  end

  defp same_kind?([]), do: false
  defp same_kind?(variants), do: variants |> Enum.map(& &1.kind) |> Enum.uniq() |> length() == 1

  # Only kinds that carry no structure collapse safely. Anything else keeps its
  # variants: merging `[integer()] | [string()]` into the first array would drop
  # a whole branch of the value domain.
  @scalar_kinds [:float, :number, :boolean, :atom, :null, :any]

  defp merge_same_kind_list([%Type{kind: :integer} | _] = variants),
    do: merge_integer_ranges(variants)

  defp merge_same_kind_list([%Type{kind: kind} | _] = variants) when kind in @scalar_kinds,
    do: {:ok, hd(variants)}

  defp merge_same_kind_list(_variants), do: :error

  # The union of two integer domains is representable as one interval only when
  # the intervals overlap or touch. `nil` bounds are infinities: any variant
  # that is unbounded on a side must keep the union unbounded on that side.
  defp merge_integer_ranges(variants) do
    bounds =
      variants
      |> Enum.map(&{&1.minimum, &1.maximum})
      |> Enum.sort_by(fn {low, _high} -> {low != nil, low || 0} end)
      |> coalesce()

    case bounds do
      [{minimum, maximum}] -> {:ok, %Type{kind: :integer, minimum: minimum, maximum: maximum}}
      _gaps -> :error
    end
  end

  defp coalesce(intervals) do
    intervals
    |> Enum.reduce([], &insert_interval/2)
    |> Enum.reverse()
  end

  defp insert_interval(interval, []), do: [interval]

  defp insert_interval(interval, [current | rest] = acc) do
    if touches?(current, interval),
      do: [widen(current, interval) | rest],
      else: [interval | acc]
  end

  defp touches?({_low, high}, {next_low, _high}) when is_nil(high) or is_nil(next_low), do: true
  defp touches?({_low, high}, {next_low, _high}), do: next_low <= high + 1

  defp widen({low, high}, {next_low, next_high}) do
    {if(is_nil(low) or is_nil(next_low), do: nil, else: min(low, next_low)),
     if(is_nil(high) or is_nil(next_high), do: nil, else: max(high, next_high))}
  end

  # Structural equality, without the provenance the schema never uses.
  defp signature(%Type{} = type), do: %{type | source: nil, nullable: false}

  defp singleton?(%Type{kind: :enum, values: [_ | _]}), do: true

  defp singleton?(%Type{kind: :integer, minimum: same, maximum: same}) when not is_nil(same),
    do: true

  defp singleton?(_), do: false

  defp singleton_value(%Type{kind: :enum, values: [value]}), do: value
  defp singleton_value(%Type{kind: :integer, minimum: value}), do: value

  defp build_object(pairs) do
    {fields, additional} =
      Enum.reduce(pairs, {[], nil}, fn
        {{:required, _, [key]}, type}, {fields, additional} when is_atom(key) ->
          {[field(key, type, true) | fields], additional}

        {{:optional, _, [key]}, type}, {fields, additional} when is_atom(key) ->
          {[field(key, type, false) | fields], additional}

        {key, type}, {fields, additional} when is_atom(key) ->
          {[field(key, type, true) | fields], additional}

        {_key_type, type}, {fields, _additional} ->
          {fields, to_type(type)}
      end)

    %Type{kind: :object, fields: Enum.reverse(fields), additional: additional}
  end

  defp field(key, type, required?) do
    %Field{name: Atom.to_string(key), key: key, type: to_type(type), required: required?}
  end
end
