defmodule ToolCall.Validate do
  @moduledoc false
  # Checks a value against the IR's value domain. This is the inverse direction
  # of `ToolCall.Coerce`: a value that the declared type accepts passes, and no
  # wire form is accepted in its place (`"1"` is not an integer, `"true"` is not
  # a boolean, `"2024-01-01"` is not a `%Date{}`).
  #
  # A provider type's `kind` describes its *wire* form, so a node carrying a
  # `validator` is checked by that validator instead of by its kind. A node with
  # a `transform` and no validator describes a domain the library cannot see, so
  # it is accepted.

  alias ToolCall.IR.{Field, Type}

  @spec valid?(Type.t(), term(), %{String.t() => Type.t()}) :: :ok | {:error, term()}
  def valid?(%Type{nullable: true}, nil, _defs), do: :ok

  def valid?(%Type{validator: {module, function}}, value, _defs) do
    check_validator(module, function, value)
  end

  def valid?(%Type{transform: transform}, _value, _defs) when not is_nil(transform), do: :ok

  def valid?(%Type{kind: :integer} = type, value, _defs) do
    if is_integer(value) do
      check_bounds(type, value)
    else
      {:error, {:expected_integer, value}}
    end
  end

  def valid?(%Type{kind: :float}, value, _defs) do
    if is_float(value), do: :ok, else: {:error, {:expected_float, value}}
  end

  def valid?(%Type{kind: :number}, value, _defs) do
    if is_number(value), do: :ok, else: {:error, {:expected_number, value}}
  end

  def valid?(%Type{kind: :string} = type, value, _defs), do: check_string(type, value)

  def valid?(%Type{kind: :boolean}, value, _defs) do
    if is_boolean(value), do: :ok, else: {:error, {:expected_boolean, value}}
  end

  def valid?(%Type{kind: :atom}, value, _defs) do
    if is_atom(value), do: :ok, else: {:error, {:expected_atom, value}}
  end

  def valid?(%Type{kind: :enum} = type, value, _defs) do
    cond do
      type.values in [nil, []] -> :ok
      value in type.values -> :ok
      true -> {:error, {:invalid_enum, value, type.values}}
    end
  end

  def valid?(%Type{kind: :null}, value, _defs) do
    if is_nil(value), do: :ok, else: {:error, {:expected_null, value}}
  end

  def valid?(%Type{kind: kind}, _value, _defs) when kind in [:any, :unsupported], do: :ok

  def valid?(%Type{kind: :array} = type, value, defs) when is_list(value) do
    item_type = type.items || %Type{kind: :any}
    minimum = type.minimum || 0
    maximum = type.maximum
    length = length(value)

    cond do
      length < minimum -> {:error, {:too_few_items, length, minimum}}
      not is_nil(maximum) and length > maximum -> {:error, {:too_many_items, length, maximum}}
      true -> check_each(item_type, value, defs)
    end
  end

  def valid?(%Type{kind: :array}, value, _defs), do: {:error, {:expected_array, value}}

  def valid?(%Type{kind: :tuple, items: nil}, value, _defs) do
    if is_tuple(value), do: :ok, else: {:error, {:expected_tuple, value}}
  end

  def valid?(%Type{kind: :tuple} = type, value, defs) when is_tuple(value) do
    items = type.items || []
    values = Tuple.to_list(value)

    if length(values) == length(items) do
      check_each(items, values, defs)
    else
      {:error, {:wrong_tuple_size, length(values), length(items)}}
    end
  end

  def valid?(%Type{kind: :tuple}, value, _defs), do: {:error, {:expected_tuple, value}}

  def valid?(%Type{kind: :object, struct: struct} = type, value, defs)
      when not is_nil(struct) do
    if is_struct(value, struct) do
      check_fields(type.fields || [], value, defs)
    else
      {:error, {:expected_struct, value}}
    end
  end

  def valid?(%Type{kind: :object} = type, value, defs) do
    if is_map(value) do
      check_fields_with_extra(type, value, defs)
    else
      {:error, {:expected_object, value}}
    end
  end

  def valid?(%Type{kind: :union} = type, value, defs) do
    if Enum.any?(type.variants || [], &(valid?(&1, value, defs) == :ok)) do
      :ok
    else
      {:error, {:no_variant_matched, value}}
    end
  end

  def valid?(%Type{kind: :ref, ref: ref}, value, defs) do
    case Map.fetch(defs, ref) do
      {:ok, type} -> valid?(type, value, defs)
      :error -> raise ArgumentError, "invalid ToolCall IR: unknown $defs entry #{inspect(ref)}"
    end
  end

  def valid?(%Type{kind: kind}, _value, _defs) do
    raise ArgumentError, "invalid ToolCall IR: cannot validate kind #{inspect(kind)}"
  end

  # --- validators -----------------------------------------------------------

  defp check_validator(module, function, value) do
    case apply(module, function, [value]) do
      true -> :ok
      _other -> {:error, {:validator, {module, function}, value}}
    end
  rescue
    exception -> {:error, {:validate_raised, Exception.message(exception)}}
  catch
    :throw, value -> {:error, {:validate_raised, value}}
    :exit, reason -> {:error, {:validate_raised, reason}}
  end

  defp check_bounds(%Type{} = type, integer) do
    below? = not is_nil(type.minimum) and integer < type.minimum
    above? = not is_nil(type.maximum) and integer > type.maximum

    cond do
      below? -> {:error, {:below_minimum, integer, type.minimum}}
      above? -> {:error, {:above_maximum, integer, type.maximum}}
      true -> :ok
    end
  end

  defp check_string(%Type{source: :binary}, value) do
    if is_binary(value), do: :ok, else: {:error, {:expected_string, value}}
  end

  defp check_string(%Type{source: :bitstring}, value) do
    if is_bitstring(value), do: :ok, else: {:error, {:expected_bitstring, value}}
  end

  defp check_string(%Type{source: :nonempty_binary}, value) do
    if is_binary(value) and byte_size(value) > 0,
      do: :ok,
      else: {:error, {:expected_string, value}}
  end

  defp check_string(%Type{source: :char}, value) do
    if is_integer(value) and value >= 0 and value <= 0x10FFFF,
      do: :ok,
      else: {:error, {:expected_char, value}}
  end

  defp check_string(%Type{source: :charlist}, value) do
    if is_list(value) and Enum.all?(value, &is_integer/1),
      do: :ok,
      else: {:error, {:expected_charlist, value}}
  end

  defp check_string(%Type{} = type, value) when is_binary(value) do
    cond do
      not String.valid?(value) ->
        {:error, {:invalid_utf8, value}}

      is_nil(type.pattern_regex) ->
        :ok

      Regex.match?(type.pattern_regex, value) ->
        :ok

      true ->
        {:error, {:pattern_mismatch, type.pattern, value}}
    end
  end

  defp check_string(%Type{}, value), do: {:error, {:expected_string, value}}

  defp check_each(types, values, defs) when is_list(types) do
    types
    |> Enum.zip(values)
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {{type, value}, index}, :ok ->
      case valid?(type, value, defs) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {index, reason}}}
      end
    end)
  end

  defp check_each(type, values, defs) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {value, index}, :ok ->
      case valid?(type, value, defs) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {index, reason}}}
      end
    end)
  end

  defp check_fields_with_extra(%Type{} = type, value, defs) do
    fields = type.fields || []
    known = MapSet.new(fields, &field_key/1)

    extra =
      if is_nil(type.additional) do
        Map.keys(value) |> Enum.reject(&MapSet.member?(known, &1)) |> Enum.map(&to_string/1)
      else
        []
      end

    with :ok <- check_fields(fields, value, defs),
         :ok <- check_extra(type, value, known, defs) do
      case extra do
        [] -> :ok
        keys -> {:error, {:unknown_keys, keys}}
      end
    end
  end

  defp check_fields(fields, value, defs) do
    Enum.reduce_while(fields, :ok, fn field, :ok -> check_field(field, value, defs) end)
  end

  defp check_field(%Field{} = field, value, defs) do
    case Map.fetch(value, field_key(field)) do
      {:ok, raw} -> check_field_value(field, raw, defs)
      :error when field.required -> {:halt, {:error, {:missing_field, field.name}}}
      :error -> {:cont, :ok}
    end
  end

  defp check_field_value(%Field{} = field, raw, defs) do
    case valid?(field.type, raw, defs) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, {field.name, reason}}}
    end
  end

  defp check_extra(%Type{additional: nil}, _value, _known, _defs), do: :ok

  defp check_extra(%Type{additional: %Type{kind: :any}}, _value, _known, _defs), do: :ok

  defp check_extra(%Type{additional: additional}, value, known, defs) do
    value
    |> Enum.reject(fn {key, _value} -> MapSet.member?(known, key) end)
    |> Enum.reduce_while(:ok, fn {key, raw}, :ok ->
      case valid?(additional, raw, defs) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {to_string(key), reason}}}
      end
    end)
  end

  defp field_key(%Field{key: nil, name: name}), do: name
  defp field_key(%Field{key: key}), do: key
end
