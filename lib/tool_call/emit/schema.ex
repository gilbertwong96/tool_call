defmodule ToolCall.Emit.Schema do
  @moduledoc """
  JSON Schema rendering shared by the provider emitters.

  Deliberately emits a conservative subset: no `$ref`, no `$defs`, no
  `oneOf`. Recursive types are not supported yet (see `docs/design.md`).
  """

  alias ToolCall.IR.{Field, Param, Tool, Type}

  @doc "Renders the `parameters`/`input_schema` object for a tool."
  @spec params(Tool.t(), keyword()) :: map()
  def params(%Tool{} = tool, opts \\ []) do
    ToolCall.Typespec.validate_tool!(tool)
    params = tool.params || []
    params = if strict?(opts), do: Enum.map(params, &force_required/1), else: params

    %{
      "type" => "object",
      "properties" => Map.new(params, &{&1.name, param(&1, opts)}),
      "required" => for(p <- params, p.required, do: p.name),
      "additionalProperties" => false
    }
  end

  @doc false
  @spec strict?(keyword()) :: boolean()
  def strict?(opts) do
    case Keyword.get(opts, :strict, false) do
      value when is_boolean(value) -> value
      nil -> false
      other -> raise ArgumentError, "strict must be a boolean, got: #{inspect(other)}"
    end
  end

  @doc "Renders a single type node."
  @spec type(Type.t(), keyword()) :: map()
  def type(%Type{} = type, opts \\ []) do
    type
    |> ToolCall.Typespec.validate_type!()
    |> do_type(opts)
  end

  defp do_type(%Type{} = type, opts) do
    type
    |> base(opts)
    |> nullable(type)
  end

  defp base(%Type{kind: :integer} = type, _opts), do: bounds(%{"type" => "integer"}, type)
  defp base(%Type{kind: :float}, _opts), do: %{"type" => "number"}
  defp base(%Type{kind: :number}, _opts), do: %{"type" => "number"}

  defp base(%Type{kind: :string} = type, _opts) do
    %{"type" => "string"}
    |> maybe_put("format", type.format)
    |> pattern(type)
  end

  defp base(%Type{kind: :boolean}, _opts), do: %{"type" => "boolean"}
  defp base(%Type{kind: :atom}, _opts), do: %{"type" => "string"}
  defp base(%Type{kind: :null}, _opts), do: %{"type" => "null"}
  defp base(%Type{kind: :any}, _opts), do: %{}
  defp base(%Type{kind: :unsupported}, _opts), do: %{}
  defp base(%Type{kind: :enum} = type, _opts), do: enum(type)
  defp base(%Type{kind: :array} = type, opts), do: array(type, opts)
  defp base(%Type{kind: :tuple} = type, opts), do: tuple(type, opts)
  defp base(%Type{kind: :object} = type, opts), do: object(type, opts)

  defp base(%Type{kind: :union} = type, opts),
    do: %{"anyOf" => Enum.map(type.variants, &do_type(&1, opts))}

  defp param(%Param{} = param, opts) do
    schema =
      case param.wire do
        :string_integer -> string_integer(param.type)
        _wire -> do_type(param.type, opts)
      end

    put_default(schema, param, opts)
    |> put_description(param)
  end

  defp put_description(schema, %Param{description: nil}), do: schema

  defp put_description(schema, %Param{description: description}),
    do: Map.put(schema, "description", description)

  # Large integers are carried as decimal strings; see docs/number-handling.md.
  defp string_integer(%Type{nullable: true}),
    do: %{"type" => ["string", "null"], "pattern" => "^-?\\d+$"}

  defp string_integer(%Type{}), do: %{"type" => "string", "pattern" => "^-?\\d+$"}

  defp put_default(schema, %Param{default: nil}, _opts), do: schema

  defp put_default(schema, %Param{wire: :string_integer} = param, opts) do
    if strict?(opts) or not is_integer(param.default) do
      schema
    else
      Map.put(schema, "default", Integer.to_string(param.default))
    end
  end

  defp put_default(schema, %Param{type: %Type{source: :charlist}} = param, opts) do
    if strict?(opts) do
      schema
    else
      case charlist_default(param.default) do
        nil -> schema
        text -> Map.put(schema, "default", text)
      end
    end
  end

  defp put_default(schema, %Param{} = param, opts) do
    # The API rejects `default` in strict mode; nullability carries the same idea.
    if strict?(opts),
      do: schema,
      else: Map.put(schema, "default", atom_default(param.type, param.default))
  end

  # `atom()` is a string on the wire, so an atom default must be rendered as one
  # too. The walk follows arrays and objects so nested defaults match their schema.
  defp atom_default(%Type{kind: :atom, nullable: true}, nil), do: nil
  defp atom_default(%Type{kind: :atom}, value) when is_atom(value), do: Atom.to_string(value)

  defp atom_default(%Type{kind: :union, nullable: true}, nil), do: nil

  defp atom_default(%Type{kind: :union, variants: variants}, value) when is_atom(value) do
    if Enum.any?(variants || [], &(&1.kind == :atom)), do: Atom.to_string(value), else: value
  end

  defp atom_default(%Type{kind: :array, items: items}, values) when is_list(values),
    do: Enum.map(values, &atom_default(items || %Type{kind: :any}, &1))

  defp atom_default(%Type{kind: :tuple, items: items}, values) when is_list(values) do
    items = items || []

    if length(items) == length(values),
      do: Enum.zip_with(items, values, &atom_default/2),
      else: values
  end

  defp atom_default(%Type{kind: :object} = type, value) when is_map(value) do
    fields = type.fields || []

    Map.new(value, fn {key, item} ->
      {key, atom_default(field_type(fields, key) || type.additional || %Type{kind: :any}, item)}
    end)
  end

  defp atom_default(_type, value), do: value

  defp field_type(fields, key) do
    Enum.find_value(fields, fn field ->
      if field.key == key or field.name == key, do: field.type
    end)
  end

  defp force_required(%Param{required: true} = param), do: param

  defp force_required(%Param{} = param) do
    %{param | required: true, type: %{param.type | nullable: true}}
  end

  defp bounds(schema, %Type{} = type) do
    schema
    |> maybe_put("minimum", type.minimum)
    |> maybe_put("maximum", type.maximum)
  end

  defp pattern(schema, %Type{pattern: nil}), do: schema
  defp pattern(schema, %Type{pattern: pattern}), do: Map.put(schema, "pattern", pattern)

  defp enum(%Type{values: values}) do
    cond do
      values in [nil, []] ->
        %{"type" => "string"}

      Enum.all?(values, &is_boolean/1) ->
        %{"type" => "boolean", "enum" => values}

      Enum.all?(values, &is_atom/1) and
          not Enum.any?(values, &(is_boolean(&1) or is_nil(&1))) ->
        %{"type" => "string", "enum" => Enum.map(values, &Atom.to_string/1)}

      Enum.all?(values, &is_integer/1) ->
        %{"type" => "integer", "enum" => values}

      true ->
        %{"enum" => values}
    end
  end

  defp array(%Type{} = type, opts) do
    %{
      "type" => "array",
      "items" => do_type(type.items || %Type{kind: :any}, opts)
    }
    |> maybe_put("minItems", type.minimum)
  end

  defp tuple(%Type{} = type, opts) do
    items = Enum.map(type.items || [], &do_type(&1, opts))
    size = length(items)

    schema = %{"type" => "array", "minItems" => size, "maxItems" => size}

    if strict?(opts),
      do: Map.put(schema, "items", %{}),
      else: Map.put(schema, "prefixItems", items)
  end

  defp object(%Type{} = type, opts) do
    fields = type.fields || []
    fields = if strict?(opts), do: Enum.map(fields, &force_field_required/1), else: fields
    additional = if strict?(opts), do: nil, else: type.additional

    %{
      "type" => "object",
      "properties" => Map.new(fields, &{&1.name, do_type(&1.type, opts)}),
      "required" => for(field <- fields, field.required, do: field.name)
    }
    |> put_additional(additional, opts)
  end

  defp force_field_required(%Field{required: true} = field), do: field

  defp force_field_required(%Field{} = field) do
    %{field | required: true, type: %{field.type | nullable: true}}
  end

  defp put_additional(schema, nil, _opts), do: Map.put(schema, "additionalProperties", false)

  defp put_additional(schema, %Type{kind: :any}, _opts),
    do: Map.put(schema, "additionalProperties", true)

  defp put_additional(schema, %Type{} = additional, opts),
    do: Map.put(schema, "additionalProperties", do_type(additional, opts))

  defp nullable(schema, %Type{nullable: true}) do
    case schema do
      # `enum` constrains independently of `type`, so widening the type is not
      # enough: null needs its own branch.
      %{"enum" => _values} -> %{"anyOf" => [schema, %{"type" => "null"}]}
      %{"type" => type} when is_binary(type) -> %{schema | "type" => [type, "null"]}
      %{"anyOf" => variants} -> %{"anyOf" => variants ++ [%{"type" => "null"}]}
      _ -> %{"anyOf" => [schema, %{"type" => "null"}]}
    end
  end

  defp nullable(schema, %Type{}), do: schema

  defp charlist_default(value) when is_binary(value), do: value

  defp charlist_default(value) when is_list(value) do
    List.to_string(value)
  rescue
    _ -> nil
  end

  defp charlist_default(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
