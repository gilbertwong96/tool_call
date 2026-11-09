defmodule ToolCall.Coerce do
  @moduledoc """
  Runtime normalisation of decoded JSON arguments into the value domains that
  typespecs promise.

  Two mismatches motivate this module:

    * JSON Schema `integer` accepts `1.0`, while Elixir `integer()` does not.
      Integral floats are truncated.
    * JSON has no atoms, so `:enum` values arrive as strings and are mapped
      back to atoms.

  JSON strings are Unicode; invalid UTF-8 binaries are rejected with
  `{:invalid_utf8, value}` so a bad provider payload never raises out of
  `ToolCall.run/3`.

  Patterns must already be compiled into `ToolCall.IR.Type.pattern_regex`.
  Hand-built types can be prepared with `ToolCall.Typespec.validate_type!/1`.

  See `docs/number-handling.md`.
  """

  alias ToolCall.IR.{Field, Param, Type}

  # DBL_MAX; an integer above it cannot be widened without raising ArithmeticError.
  @max_float 1.797_693_134_862_315_7e308

  @spec param(Param.t(), term(), %{String.t() => Type.t()}) ::
          {:ok, term()} | {:error, term()}
  def param(%Param{} = param, value, defs \\ %{}) do
    case coerce(param.type, value, param.wire, defs) do
      {:ok, coerced} -> {:ok, coerced}
      {:error, reason} -> {:error, {param.name, reason}}
    end
  end

  @spec coerce(Type.t(), term(), Param.wire(), %{String.t() => Type.t()}) ::
          {:ok, term()} | {:error, term()}
  def coerce(type, value, wire \\ :number, defs \\ %{})

  # Nullability belongs to the value domain, so it wins over the wire format.
  def coerce(%Type{nullable: true}, nil, _wire, _defs), do: {:ok, nil}

  def coerce(%Type{} = type, value, wire, defs) do
    with {:ok, coerced} <- coerce_value(type, value, wire, defs) do
      transform(type, coerced)
    end
  end

  @doc false
  @spec simple_string(term()) :: {:ok, String.t()} | {:error, term()}
  def simple_string(value) when is_binary(value) do
    if String.valid?(value), do: {:ok, value}, else: {:error, {:invalid_utf8, value}}
  end

  def simple_string(value), do: {:error, {:expected_string, value}}

  @doc false
  @spec simple_integer(term(), integer() | nil, integer() | nil) ::
          {:ok, integer()} | {:error, term()}
  def simple_integer(value, minimum, maximum) do
    cond do
      is_integer(value) -> simple_bounds(value, minimum, maximum)
      is_float(value) and value == trunc(value) -> simple_bounds(trunc(value), minimum, maximum)
      true -> {:error, {:expected_integer, value}}
    end
  end

  @doc false
  @spec simple_float(term(), number() | nil, number() | nil) ::
          {:ok, float()} | {:error, term()}
  def simple_float(value, minimum, maximum) do
    cond do
      is_float(value) ->
        simple_bounds(value, minimum, maximum)

      is_integer(value) ->
        if abs(value) <= @max_float,
          do: simple_bounds(value * 1.0, minimum, maximum),
          else: {:error, {:expected_float, value}}

      true ->
        {:error, {:expected_float, value}}
    end
  end

  @doc false
  @spec simple_number(term(), number() | nil, number() | nil) ::
          {:ok, number()} | {:error, term()}
  def simple_number(value, minimum, maximum) when is_number(value),
    do: simple_bounds(value, minimum, maximum)

  def simple_number(value, _minimum, _maximum), do: {:error, {:expected_number, value}}

  @doc false
  @spec simple_boolean(term()) :: {:ok, boolean()} | {:error, term()}
  def simple_boolean(value) when is_boolean(value), do: {:ok, value}
  def simple_boolean(value), do: {:error, {:expected_boolean, value}}

  @doc false
  @spec simple_atom(term()) :: {:ok, atom()} | {:error, term()}
  def simple_atom(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: {:ok, value}

  def simple_atom(value) when is_binary(value) do
    if String.valid?(value) do
      atom = String.to_existing_atom(value)

      if is_boolean(atom) or is_nil(atom),
        do: {:error, {:expected_atom, value}},
        else: {:ok, atom}
    else
      {:error, {:invalid_utf8, value}}
    end
  rescue
    ArgumentError -> {:error, {:unknown_atom, value}}
  end

  def simple_atom(value), do: {:error, {:expected_atom, value}}

  @doc false
  @spec simple_null(term()) :: {:ok, nil} | {:error, term()}
  def simple_null(nil), do: {:ok, nil}
  def simple_null(value), do: {:error, {:expected_null, value}}

  @doc false
  @spec simple_any(term()) :: {:ok, term()}
  def simple_any(value), do: {:ok, value}

  defp simple_bounds(value, nil, nil), do: {:ok, value}

  defp simple_bounds(value, minimum, maximum) do
    below? = not is_nil(minimum) and value < minimum
    above? = not is_nil(maximum) and value > maximum

    cond do
      below? -> {:error, {:below_minimum, value, minimum}}
      above? -> {:error, {:above_maximum, value, maximum}}
      true -> {:ok, value}
    end
  end

  @doc false
  @spec accepts_nil?(Type.t(), %{String.t() => Type.t()}) :: boolean()
  def accepts_nil?(type, defs \\ %{})

  def accepts_nil?(%Type{nullable: true}, _defs), do: true
  def accepts_nil?(%Type{kind: :null}, _defs), do: true
  def accepts_nil?(%Type{kind: :any}, _defs), do: true

  def accepts_nil?(%Type{kind: :ref, ref: ref}, defs) do
    case Map.fetch(defs, ref) do
      {:ok, type} -> accepts_nil?(type, defs)
      :error -> false
    end
  end

  def accepts_nil?(%Type{kind: :enum, values: values}, _defs) when is_list(values),
    do: nil in values

  def accepts_nil?(%Type{kind: :union, variants: variants}, defs) when is_list(variants),
    do: Enum.any?(variants, &accepts_nil?(&1, defs))

  def accepts_nil?(%Type{}, _defs), do: false

  # Large integers carried as strings. See docs/number-handling.md.
  defp coerce_value(%Type{kind: :integer} = type, value, :string_integer, _defs) do
    with {:ok, integer} <- parse_integer(value) do
      check_bounds(type, integer)
    end
  end

  defp coerce_value(%Type{kind: :ref, ref: ref}, value, _wire, defs) do
    case Map.fetch(defs, ref) do
      {:ok, type} ->
        coerce(type, value, :number, defs)

      :error ->
        raise ArgumentError, "invalid ToolCall IR: unknown $defs entry #{inspect(ref)}"
    end
  end

  defp coerce_value(%Type{} = type, value, _wire, defs) do
    cond do
      type.kind == :any -> {:ok, value}
      type.kind == :unsupported -> {:error, :unsupported_type}
      true -> coerce_kind(type, value, defs)
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

  defp coerce_kind(%Type{kind: :integer} = type, value, _defs) do
    cond do
      is_integer(value) -> check_bounds(type, value)
      is_float(value) and value == trunc(value) -> check_bounds(type, trunc(value))
      true -> {:error, {:expected_integer, value}}
    end
  end

  defp coerce_kind(%Type{kind: :float} = type, value, _defs) when is_float(value),
    do: check_bounds(type, value)

  defp coerce_kind(%Type{kind: :float} = type, value, _defs) when is_integer(value) do
    if abs(value) <= @max_float,
      do: check_bounds(type, value * 1.0),
      else: {:error, {:expected_float, value}}
  end

  defp coerce_kind(%Type{kind: :float}, value, _defs), do: {:error, {:expected_float, value}}

  defp coerce_kind(%Type{kind: :number} = type, value, _defs) when is_number(value),
    do: check_bounds(type, value)

  defp coerce_kind(%Type{kind: :number}, value, _defs),
    do: {:error, {:expected_number, value}}

  defp coerce_kind(%Type{kind: :string, source: :charlist}, value, _defs)
       when is_binary(value) do
    if String.valid?(value),
      do: {:ok, String.to_charlist(value)},
      else: {:error, {:invalid_utf8, value}}
  end

  defp coerce_kind(%Type{kind: :string, source: :char} = type, value, _defs)
       when is_binary(value) do
    cond do
      not String.valid?(value) ->
        {:error, {:invalid_utf8, value}}

      Regex.match?(pattern_regex(type), value) ->
        [codepoint | _rest] = String.to_charlist(value)
        {:ok, codepoint}

      true ->
        {:error, {:pattern_mismatch, type.pattern, value}}
    end
  end

  defp coerce_kind(%Type{kind: :string, pattern: nil}, value, _defs) when is_binary(value) do
    if String.valid?(value), do: {:ok, value}, else: {:error, {:invalid_utf8, value}}
  end

  defp coerce_kind(%Type{kind: :string, pattern: pattern} = type, value, _defs)
       when is_binary(value) do
    cond do
      not String.valid?(value) ->
        {:error, {:invalid_utf8, value}}

      Regex.match?(pattern_regex(type), value) ->
        {:ok, value}

      true ->
        {:error, {:pattern_mismatch, pattern, value}}
    end
  end

  defp coerce_kind(%Type{kind: :string}, value, _defs),
    do: {:error, {:expected_string, value}}

  defp coerce_kind(%Type{kind: :boolean}, value, _defs) when is_boolean(value),
    do: {:ok, value}

  defp coerce_kind(%Type{kind: :boolean}, value, _defs),
    do: {:error, {:expected_boolean, value}}

  defp coerce_kind(%Type{kind: :null}, nil, _defs), do: {:ok, nil}
  defp coerce_kind(%Type{kind: :null}, value, _defs), do: {:error, {:expected_null, value}}

  defp coerce_kind(%Type{kind: :atom}, value, _defs), do: simple_atom(value)

  defp coerce_kind(%Type{kind: :enum} = type, value, _defs), do: coerce_enum(type, value)

  defp coerce_kind(%Type{kind: :array} = type, value, defs) when is_list(value) do
    with {:ok, items} <- coerce_each(type.items || %Type{kind: :any}, value, defs) do
      length = length(items)
      minimum = type.minimum || 0
      maximum = type.maximum

      cond do
        length < minimum ->
          {:error, {:too_few_items, length, minimum}}

        not is_nil(maximum) and length > maximum ->
          {:error, {:too_many_items, length, maximum}}

        true ->
          {:ok, items}
      end
    end
  end

  defp coerce_kind(%Type{kind: :array}, value, _defs),
    do: {:error, {:expected_array, value}}

  defp coerce_kind(%Type{kind: :tuple, items: nil}, value, _defs) when is_list(value),
    do: {:ok, List.to_tuple(value)}

  defp coerce_kind(%Type{kind: :tuple} = type, value, defs) when is_list(value) do
    items = type.items || []

    if length(value) == length(items) do
      coerce_tuple(items, value, defs)
    else
      {:error, {:wrong_tuple_size, length(value), length(items)}}
    end
  end

  defp coerce_kind(%Type{kind: :tuple}, value, _defs),
    do: {:error, {:expected_array, value}}

  defp coerce_kind(%Type{kind: :object} = type, value, defs) when is_map(value) do
    fields = type.fields || []

    with {:ok, known} <- coerce_fields(fields, value, defs),
         {:ok, extra} <- coerce_extra(type, value, fields, defs) do
      {:ok, Map.merge(known, extra)}
    end
  end

  defp coerce_kind(%Type{kind: :object}, value, _defs),
    do: {:error, {:expected_object, value}}

  defp coerce_kind(%Type{kind: :union} = type, value, defs) do
    variants = type.variants || []

    Enum.reduce_while(variants, {:error, {:no_variant_matched, value}}, fn variant, _acc ->
      case coerce(variant, value, :number, defs) do
        {:ok, coerced} -> {:halt, {:ok, coerced}}
        {:error, _reason} -> {:cont, {:error, {:no_variant_matched, value}}}
      end
    end)
  end

  defp coerce_enum(%Type{} = type, value) when is_binary(value) do
    if String.valid?(value),
      do: coerce_enum_value(type, value),
      else: {:error, {:invalid_utf8, value}}
  end

  defp coerce_enum(%Type{} = type, value), do: coerce_enum_value(type, value)

  defp coerce_enum_value(%Type{values: nil}, value), do: coerce_empty_enum(value)
  defp coerce_enum_value(%Type{values: []}, value), do: coerce_empty_enum(value)

  defp coerce_enum_value(%Type{values: values}, value) do
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

  # An empty enum renders as an unconstrained string schema; keep dispatch in
  # sync instead of rejecting every value the schema advertises.
  defp coerce_empty_enum(value) when is_binary(value), do: {:ok, value}
  defp coerce_empty_enum(value), do: {:error, {:invalid_enum, value, []}}

  defp parse_integer(value) when is_integer(value), do: {:ok, value}

  defp parse_integer(value) when is_binary(value) do
    cond do
      not String.valid?(value) ->
        {:error, {:invalid_utf8, value}}

      String.starts_with?(value, "+") ->
        {:error, {:expected_integer_string, value}}

      true ->
        case Integer.parse(value) do
          {integer, ""} -> {:ok, integer}
          _other -> {:error, {:expected_integer_string, value}}
        end
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

  defp coerce_each(_type, [], _defs), do: {:ok, []}

  defp coerce_each(type, values, defs) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
      case coerce(type, value, :number, defs) do
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
  defp coerce_tuple(items, values, defs) do
    items
    |> Enum.zip(values)
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {{item_type, value}, index}, {:ok, acc} ->
      case coerce(item_type, value, :number, defs) do
        {:ok, coerced} -> {:cont, {:ok, [coerced | acc]}}
        {:error, reason} -> {:halt, {:error, {index, reason}}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, reversed |> Enum.reverse() |> List.to_tuple()}
      error -> error
    end
  end

  defp coerce_fields(fields, value, defs) do
    Enum.reduce_while(fields, {:ok, %{}}, fn field, {:ok, acc} ->
      case coerce_field(field, value, defs) do
        {:ok, :missing} -> {:cont, {:ok, acc}}
        {:ok, coerced} -> {:cont, {:ok, Map.put(acc, field_key(field), coerced)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp coerce_field(%Field{} = field, value, defs) do
    case Map.fetch(value, field.name) do
      {:ok, nil} when not field.required ->
        if accepts_nil?(field.type, defs),
          do: coerce_field_value(field, nil, defs),
          else: {:ok, :missing}

      {:ok, raw} ->
        coerce_field_value(field, raw, defs)

      :error ->
        missing_field(field)
    end
  end

  defp coerce_field_value(%Field{name: name, type: type}, raw, defs) do
    case coerce(type, raw, :number, defs) do
      {:ok, coerced} -> {:ok, coerced}
      {:error, reason} -> {:error, {name, reason}}
    end
  end

  defp missing_field(%Field{required: true, name: name}), do: {:error, {:missing, name}}
  defp missing_field(%Field{}), do: {:ok, :missing}

  defp field_key(%Field{key: nil, name: name}), do: name
  defp field_key(%Field{key: key}), do: key

  defp coerce_extra(%Type{} = type, value, fields, defs) do
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
        coerce_fields_for_extra(type.additional, extra, defs)
    end
  end

  # Patterns are compiled when the IR is built; `Coerce` never compiles them
  # on demand. Hand-built types must set `pattern_regex` or go through
  # `ToolCall.Typespec.validate_type!/1`.
  defp pattern_regex(%Type{pattern_regex: %Regex{} = regex}), do: regex

  defp pattern_regex(%Type{pattern: pattern}) do
    raise ArgumentError,
          "invalid ToolCall IR: pattern #{inspect(pattern)} has no compiled pattern_regex; " <>
            "use ToolCall.Typespec.validate_type!/1 or set pattern_regex"
  end

  defp coerce_fields_for_extra(additional, extra, defs) do
    Enum.reduce_while(extra, {:ok, %{}}, fn {key, raw}, {:ok, acc} ->
      case coerce(additional, raw, :number, defs) do
        {:ok, coerced} -> {:cont, {:ok, Map.put(acc, key, coerced)}}
        {:error, reason} -> {:halt, {:error, {key, reason}}}
      end
    end)
  end
end
