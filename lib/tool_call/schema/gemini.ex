defmodule ToolCall.Schema.Gemini do
  @moduledoc """
  Target-level schema adaptation that does not require `ToolCall.IR`.

  `to_gemini/2` rewrites a JSON Schema into Gemini's OpenAPI 3.0 `parameters`
  subset. It is the transformation `ToolCall.Emit.Gemini` applies after rendering
  a tool, exposed for callers that already hold a schema. It deliberately does
  not perform the strict rewrite: that needs `ToolCall.IR.Param.required` and
  remains owned by `ToolCall.Emit.Schema`. The root must be an object schema; a
  multi-type `type` array raises instead of widening to `{}`, and a null-only
  schema raises because Gemini has no null type.

  Local `$defs` references are controlled by `:on_ref`:

    * `:raise` (default) refuses the schema, matching `ToolCall.emit/3`;
    * `:drop` removes `$defs` and `$ref`, leaving their sibling keywords;
    * `:inline` substitutes non-recursive definitions and raises on a cycle.
  """

  @type on_ref :: :raise | :drop | :inline

  @schema_map_keys ~w(items not contains propertyNames if then else additionalProperties
                      unevaluatedProperties unevaluatedItems contentSchema)
  @schema_list_keys ~w(anyOf allOf oneOf prefixItems)
  @schema_map_of_maps_keys ~w(properties patternProperties dependentSchemas definitions)
  @unsupported_schema_keys ~w(oneOf const allOf not)

  @doc """
  Rewrites `schema` into Gemini's `parameters` subset.

  Options:

    * `:on_ref` - `:raise` (default), `:drop` or `:inline`; see the module
      documentation.
    * `:name` - the tool name used in the reference error message.
  """
  @spec to_gemini(map(), keyword()) :: map()
  def to_gemini(schema, opts \\ [])

  def to_gemini(schema, opts) when is_map(schema) do
    on_ref = Keyword.get(opts, :on_ref, :raise)
    validate_on_ref!(on_ref)

    schema
    |> resolve_refs(definitions(schema), on_ref, [], opts)
    |> convert(opts)
    |> validate_root!()
  end

  def to_gemini(schema, _opts) do
    raise ArgumentError, "expected a JSON Schema map, got: #{inspect(schema)}"
  end

  defp definitions(schema) do
    case Map.get(schema, "$defs") do
      nil -> %{}
      defs when is_map(defs) -> defs
      other -> raise ArgumentError, "$defs must be a map, got: #{inspect(other)}"
    end
  end

  defp validate_on_ref!(on_ref) when on_ref in [:raise, :drop, :inline], do: :ok

  defp validate_on_ref!(on_ref) do
    raise ArgumentError, "on_ref must be :raise, :drop or :inline, got: #{inspect(on_ref)}"
  end

  defp resolve_refs(schema, defs, on_ref, stack, opts) when is_map(schema) do
    schema
    |> resolve_defs(on_ref, opts)
    |> resolve_ref(defs, on_ref, stack, opts)
  end

  defp resolve_refs(schema, defs, on_ref, stack, opts) when is_list(schema) do
    Enum.map(schema, &resolve_refs(&1, defs, on_ref, stack, opts))
  end

  defp resolve_refs(schema, _defs, _on_ref, _stack, _opts), do: schema

  defp resolve_defs(schema, :raise, opts) do
    if Map.has_key?(schema, "$defs") or Map.has_key?(schema, "$ref") do
      raise_ref(opts)
    else
      schema
    end
  end

  defp resolve_defs(schema, :drop, _opts), do: Map.drop(schema, ["$defs", "$ref"])

  defp resolve_defs(schema, :inline, _opts), do: Map.delete(schema, "$defs")

  defp resolve_ref(schema, defs, :inline, stack, opts) do
    case Map.pop(schema, "$ref") do
      {nil, schema} -> walk_schema(schema, defs, :inline, stack, opts)
      {ref, siblings} -> inline_ref(ref, siblings, defs, stack, opts)
    end
  end

  defp resolve_ref(schema, defs, on_ref, stack, opts) do
    walk_schema(schema, defs, on_ref, stack, opts)
  end

  defp inline_ref(ref, siblings, defs, stack, opts) do
    if ref in stack do
      raise_ref(opts)
    end

    resolved =
      defs
      |> fetch_definition(ref, opts)
      |> resolve_refs(defs, :inline, [ref | stack], opts)

    siblings = walk_schema(siblings, defs, :inline, stack, opts)

    Map.merge(resolved, siblings)
  end

  defp fetch_definition(defs, "#/$defs/" <> name, _opts) do
    key =
      name
      |> String.replace("~1", "/")
      |> String.replace("~0", "~")

    case Map.fetch(defs, key) do
      {:ok, definition} ->
        definition

      :error ->
        raise ArgumentError,
              "Gemini function parameters reference a missing $defs entry: #{inspect(key)}"
    end
  end

  defp fetch_definition(_defs, ref, _opts) do
    raise ArgumentError,
          "Gemini function parameters can only inline local #/$defs references, got: #{inspect(ref)}"
  end

  defp walk_schema(schema, defs, on_ref, stack, opts) when is_map(schema) do
    Map.new(schema, fn {key, value} ->
      {key, walk_schema_value(key, value, defs, on_ref, stack, opts)}
    end)
  end

  defp walk_schema_value(key, value, defs, on_ref, stack, opts)
       when key in @schema_map_keys do
    resolve_refs(value, defs, on_ref, stack, opts)
  end

  defp walk_schema_value(key, value, defs, on_ref, stack, opts)
       when key in @schema_list_keys and is_list(value) do
    Enum.map(value, &resolve_refs(&1, defs, on_ref, stack, opts))
  end

  defp walk_schema_value(key, value, defs, on_ref, stack, opts)
       when key in @schema_map_of_maps_keys and is_map(value) do
    Map.new(value, fn {name, schema} ->
      {name, resolve_refs(schema, defs, on_ref, stack, opts)}
    end)
  end

  defp walk_schema_value(_key, value, _defs, _on_ref, _stack, _opts), do: value

  defp convert(%{"$defs" => _defs}, opts), do: raise_ref(opts)
  defp convert(%{"$ref" => _ref}, opts), do: raise_ref(opts)

  defp convert(schema, opts) when is_map(schema) do
    validate_supported!(schema)

    schema
    |> drop_unsupported()
    |> normalize_type()
    |> normalize_enum()
    |> collapse_nullable(opts)
    |> put_items()
    |> convert_children(opts)
  end

  defp validate_supported!(schema) do
    case Enum.find(@unsupported_schema_keys, &Map.has_key?(schema, &1)) do
      nil ->
        :ok

      key ->
        raise ArgumentError, "Gemini function parameters cannot express `#{key}`"
    end
  end

  defp validate_root!(%{"type" => "OBJECT"} = schema), do: schema

  defp validate_root!(schema) do
    raise ArgumentError,
          "Gemini function parameters require an object schema at the root, got: " <>
            inspect(Map.get(schema, "type"))
  end

  defp drop_unsupported(schema), do: Map.drop(schema, ["additionalProperties", "prefixItems"])

  defp normalize_type(%{"type" => types} = schema) when is_list(types) do
    non_null = Enum.reject(types, &(&1 == "null"))

    schema =
      case non_null do
        [] ->
          raise ArgumentError,
                "Gemini function parameters cannot express a null-only schema"

        [type] when is_binary(type) ->
          Map.put(schema, "type", String.upcase(type))

        [_type] ->
          raise ArgumentError,
                "Gemini function parameters require a string `type`, got: #{inspect(types)}"

        _many ->
          raise ArgumentError,
                "Gemini function parameters cannot express a multi-type `type` array: " <>
                  inspect(types)
      end

    if length(non_null) < length(types), do: Map.put(schema, "nullable", true), else: schema
  end

  defp normalize_type(%{"type" => "null"}) do
    raise ArgumentError, "Gemini function parameters cannot express a null-only schema"
  end

  defp normalize_type(%{"type" => type} = schema) when is_binary(type),
    do: Map.put(schema, "type", String.upcase(type))

  defp normalize_type(schema), do: schema

  defp normalize_enum(%{"enum" => values} = schema) when is_list(values) do
    if Enum.all?(values, &is_binary/1) do
      Map.put_new(schema, "format", "enum")
    else
      Map.delete(schema, "enum")
    end
  end

  defp normalize_enum(schema), do: schema

  defp collapse_nullable(%{"anyOf" => branches} = schema, opts) when is_list(branches) do
    {nulls, rest} = Enum.split_with(branches, &null_schema?/1)

    if rest == [] do
      raise ArgumentError, "Gemini function parameters cannot express a null-only schema"
    end

    schema = Map.put(schema, "anyOf", Enum.map(rest, &convert(&1, opts)))

    if nulls == [], do: schema, else: Map.put(schema, "nullable", true)
  end

  defp collapse_nullable(schema, _opts), do: schema

  defp null_schema?(%{"type" => "null"}), do: true
  defp null_schema?(_schema), do: false

  defp put_items(%{"type" => "ARRAY"} = schema), do: Map.put_new(schema, "items", %{})
  defp put_items(schema), do: schema

  defp convert_children(schema, opts) do
    schema =
      case schema do
        %{"properties" => properties} when is_map(properties) ->
          Map.put(
            schema,
            "properties",
            Map.new(properties, fn {name, property} -> {name, convert(property, opts)} end)
          )

        _other ->
          schema
      end

    case schema do
      %{"items" => %{} = items} -> Map.put(schema, "items", convert(items, opts))
      _other -> schema
    end
  end

  defp raise_ref(opts) do
    subject =
      case Keyword.get(opts, :name) do
        name when is_binary(name) -> "#{inspect(name)} uses a recursive type."
        _other -> "the schema uses a recursive type."
      end

    raise ArgumentError,
          "Gemini function parameters cannot express `$ref`/`$defs`; " <>
            subject <>
            " Use a non-recursive parameter, or send `parametersJsonSchema` yourself."
  end
end
