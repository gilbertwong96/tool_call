defmodule ToolCall.Coerce do
  @moduledoc """
  Runtime normalisation of decoded JSON arguments into the value domains that
  typespecs promise.

  Two mismatches motivate this module:

    * JSON Schema `integer` accepts `1.0`, while Elixir `integer()` does not.
      Integral floats are truncated.
    * JSON has no atoms, so `:enum` values arrive as strings and are mapped
      back to atoms.

  See `docs/number-handling.md`.
  """

  alias ToolCall.IR.{Field, Param, Type}
  alias ToolCall.Patterns

  # DBL_MAX; an integer above it cannot be widened without raising ArithmeticError.
  @max_float 1.797_693_134_862_315_7e308

  @spec param(Param.t(), term()) :: {:ok, term()} | {:error, term()}
  def param(%Param{} = param, value) do
    case coerce(param.type, value, param.wire) do
      {:ok, coerced} -> {:ok, coerced}
      {:error, reason} -> {:error, {param.name, reason}}
    end
  end

  @spec coerce(Type.t(), term(), Param.wire()) :: {:ok, term()} | {:error, term()}
  def coerce(type, value, wire \\ :number)

  # Nullability belongs to the value domain, so it wins over the wire format.
  def coerce(%Type{nullable: true}, nil, _wire), do: {:ok, nil}

  def coerce(%Type{} = type, value, wire) do
    with {:ok, coerced} <- coerce_value(type, value, wire) do
      transform(type, coerced)
    end
  end

  # Large integers carried as strings. See docs/number-handling.md.
  defp coerce_value(%Type{kind: :integer} = type, value, :string_integer) do
    with {:ok, integer} <- parse_integer(value) do
      check_bounds(type, integer)
    end
  end

  defp coerce_value(%Type{} = type, value, _wire) do
    cond do
      type.kind == :any -> {:ok, value}
      type.kind == :unsupported -> {:error, :unsupported_type}
      true -> coerce_kind(type, value)
    end
  end

  defp transform(%Type{transform: nil}, value), do: {:ok, value}

  defp transform(%Type{transform: {module, function}}, value) do
    result =
      try do
        apply(module, function, [value])
      rescue
        exception ->
          {:error, {:invalid_transform, {:raised, Exception.message(exception)}}}
      catch
        :throw, thrown -> {:error, {:invalid_transform, {:thrown, thrown}}}
        :exit, reason -> {:error, {:invalid_transform, {:exited, reason}}}
      end

    case result do
      {:ok, transformed} -> {:ok, transformed}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_transform, other}}
    end
  end

  defp transform(%Type{transform: transform}, _value) do
    {:error, {:invalid_transform, transform}}
  end

  defp coerce_kind(%Type{kind: :integer} = type, value) do
    cond do
      is_integer(value) -> check_bounds(type, value)
      is_float(value) and value == trunc(value) -> check_bounds(type, trunc(value))
      true -> {:error, {:expected_integer, value}}
    end
  end

  defp coerce_kind(%Type{kind: :float}, value) when is_float(value), do: {:ok, value}

  defp coerce_kind(%Type{kind: :float}, value) when is_integer(value) do
    if abs(value) <= @max_float,
      do: {:ok, value * 1.0},
      else: {:error, {:expected_float, value}}
  end

  defp coerce_kind(%Type{kind: :float}, value), do: {:error, {:expected_float, value}}

  defp coerce_kind(%Type{kind: :number}, value) when is_number(value), do: {:ok, value}
  defp coerce_kind(%Type{kind: :number}, value), do: {:error, {:expected_number, value}}

  defp coerce_kind(%Type{kind: :string, source: :charlist}, value) when is_binary(value),
    do: {:ok, String.to_charlist(value)}

  defp coerce_kind(%Type{kind: :string, pattern: nil}, value) when is_binary(value),
    do: {:ok, value}

  defp coerce_kind(%Type{kind: :string, pattern: pattern} = type, value)
       when is_binary(value) do
    if Regex.match?(pattern_regex(type), value),
      do: {:ok, value},
      else: {:error, {:pattern_mismatch, pattern, value}}
  end

  defp coerce_kind(%Type{kind: :string}, value), do: {:error, {:expected_string, value}}

  defp coerce_kind(%Type{kind: :boolean}, value) when is_boolean(value), do: {:ok, value}
  defp coerce_kind(%Type{kind: :boolean}, value), do: {:error, {:expected_boolean, value}}

  defp coerce_kind(%Type{kind: :null}, nil), do: {:ok, nil}
  defp coerce_kind(%Type{kind: :null}, value), do: {:error, {:expected_null, value}}

  defp coerce_kind(%Type{kind: :atom}, value)
       when is_atom(value) and not is_boolean(value) and not is_nil(value),
       do: {:ok, value}

  defp coerce_kind(%Type{kind: :atom}, value) when is_binary(value) do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError -> {:error, {:unknown_atom, value}}
  end

  defp coerce_kind(%Type{kind: :atom}, value), do: {:error, {:expected_atom, value}}

  defp coerce_kind(%Type{kind: :enum} = type, value), do: coerce_enum(type, value)

  defp coerce_kind(%Type{kind: :array} = type, value) when is_list(value) do
    with {:ok, items} <- coerce_each(type.items || %Type{kind: :any}, value) do
      minimum = type.minimum || 0

      if length(items) >= minimum do
        {:ok, items}
      else
        {:error, {:too_few_items, length(items), minimum}}
      end
    end
  end

  defp coerce_kind(%Type{kind: :array}, value), do: {:error, {:expected_array, value}}

  defp coerce_kind(%Type{kind: :tuple} = type, value) when is_list(value) do
    items = type.items || []

    if length(value) == length(items) do
      coerce_tuple(items, value)
    else
      {:error, {:wrong_tuple_size, length(value), length(items)}}
    end
  end

  defp coerce_kind(%Type{kind: :tuple}, value), do: {:error, {:expected_array, value}}

  defp coerce_kind(%Type{kind: :object} = type, value) when is_map(value) do
    fields = type.fields || []

    with {:ok, known} <- coerce_fields(fields, value),
         {:ok, extra} <- coerce_extra(type, value, fields) do
      {:ok, Map.merge(known, extra)}
    end
  end

  defp coerce_kind(%Type{kind: :object}, value), do: {:error, {:expected_object, value}}

  defp coerce_kind(%Type{kind: :union} = type, value) do
    variants = type.variants || []

    Enum.reduce_while(variants, {:error, {:no_variant_matched, value}}, fn variant, _acc ->
      case coerce(variant, value) do
        {:ok, coerced} -> {:halt, {:ok, coerced}}
        {:error, _reason} -> {:cont, {:error, {:no_variant_matched, value}}}
      end
    end)
  end

  defp coerce_enum(%Type{values: values}, value) do
    values = values || []

    cond do
      value in values ->
        {:ok, value}

      is_float(value) and value == trunc(value) and trunc(value) in values ->
        {:ok, trunc(value)}

      is_binary(value) ->
        enum_atom(values, value)

      true ->
        {:error, {:invalid_enum, value, values}}
    end
  end

  defp enum_atom(values, value) do
    case Enum.find(values, &(is_atom(&1) and Atom.to_string(&1) == value)) do
      nil -> {:error, {:invalid_enum, value, values}}
      atom -> {:ok, atom}
    end
  end

  defp parse_integer(value) when is_integer(value), do: {:ok, value}

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _other -> {:error, {:expected_integer_string, value}}
    end
  end

  defp parse_integer(value), do: {:error, {:expected_integer_string, value}}

  defp check_bounds(%Type{} = type, integer) do
    below? = not is_nil(type.minimum) and integer < type.minimum
    above? = not is_nil(type.maximum) and integer > type.maximum

    cond do
      below? -> {:error, {:below_minimum, integer, type.minimum}}
      above? -> {:error, {:above_maximum, integer, type.maximum}}
      true -> {:ok, integer}
    end
  end

  defp coerce_each(_type, []), do: {:ok, []}

  defp coerce_each(type, values) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
      case coerce(type, value) do
        {:ok, coerced} -> {:cont, {:ok, [coerced | acc]}}
        {:error, reason} -> {:halt, {:error, {index, reason}}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  # Positional types are matched by position; a list of tuples uses the generic
  # `coerce_each/2` below instead.
  defp coerce_tuple(items, values) do
    items
    |> Enum.zip(values)
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {{item_type, value}, index}, {:ok, acc} ->
      case coerce(item_type, value) do
        {:ok, coerced} -> {:cont, {:ok, [coerced | acc]}}
        {:error, reason} -> {:halt, {:error, {index, reason}}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp coerce_fields(fields, value) do
    Enum.reduce_while(fields, {:ok, %{}}, fn field, {:ok, acc} ->
      case coerce_field(field, value) do
        {:ok, :missing} -> {:cont, {:ok, acc}}
        {:ok, coerced} -> {:cont, {:ok, Map.put(acc, field_key(field), coerced)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp coerce_field(%Field{} = field, value) do
    case Map.fetch(value, field.name) do
      {:ok, nil} when not field.required -> {:ok, :missing}
      {:ok, raw} -> coerce_field_value(field, raw)
      :error -> missing_field(field)
    end
  end

  defp coerce_field_value(%Field{name: name, type: type}, raw) do
    case coerce(type, raw) do
      {:ok, coerced} -> {:ok, coerced}
      {:error, reason} -> {:error, {name, reason}}
    end
  end

  defp missing_field(%Field{required: true, name: name}), do: {:error, {:missing, name}}
  defp missing_field(%Field{}), do: {:ok, :missing}

  defp field_key(%Field{key: nil, name: name}), do: name
  defp field_key(%Field{key: key}), do: key

  defp coerce_extra(%Type{} = type, value, fields) do
    known = MapSet.new(fields, & &1.name)
    extra = Map.reject(value, fn {key, _} -> MapSet.member?(known, key) end)

    cond do
      map_size(extra) == 0 ->
        {:ok, %{}}

      is_nil(type.additional) ->
        {:error, {:unknown_keys, Map.keys(extra)}}

      type.additional.kind == :any and is_nil(type.additional.transform) ->
        {:ok, extra}

      true ->
        coerce_fields_for_extra(type.additional, extra)
    end
  end

  # Known/provider patterns are compiled into `pattern_regex`; a hand-built
  # pattern is compiled on demand instead of being cached globally.
  defp pattern_regex(%Type{pattern_regex: %Regex{} = regex}), do: regex

  defp pattern_regex(%Type{pattern: pattern}),
    do: Patterns.regex(pattern) || Regex.compile!(pattern)

  defp coerce_fields_for_extra(additional, extra) do
    Enum.reduce_while(extra, {:ok, %{}}, fn {key, raw}, {:ok, acc} ->
      case coerce(additional, raw) do
        {:ok, coerced} -> {:cont, {:ok, Map.put(acc, key, coerced)}}
        {:error, reason} -> {:halt, {:error, {key, reason}}}
      end
    end)
  end
end
