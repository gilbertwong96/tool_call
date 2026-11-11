defmodule ToolCall.Emit.Gemini do
  @moduledoc """
  Gemini function declaration (`FunctionDeclaration`).

  Gemini's `parameters` field is a 22-field subset of OpenAPI 3.0, not JSON
  Schema: types are the uppercase `Type` enum, nullability is `nullable: true`,
  and the API rejects every field the subset does not declare. The emitter
  renders the shared schema and then:

    * uppercases `type` and rewrites `type: [T, "null"]` as `nullable: true`;
    * collapses an `anyOf` null branch into `nullable: true`;
    * drops `additionalProperties` (Gemini objects are open);
    * drops `prefixItems` (no positional tuples) and keeps `minItems`/`maxItems`;
    * keeps string enums with `format: "enum"` and drops non-string enums;
    * raises for `$defs`/`$ref`, which `parameters` cannot express.

  The envelope is one declaration: `{"name", "description", "parameters"}`.
  `strict` is ignored because Gemini has no per-tool flag. When
  `additionalProperties` or recursion must be preserved, send
  `parametersJsonSchema` yourself.
  """

  alias ToolCall.Emit.Schema
  alias ToolCall.IR.Tool

  @spec emit(Tool.t(), keyword()) :: map()
  def emit(%Tool{} = tool, opts \\ []) do
    # The call validates the option shape; Gemini ignores the strict flag.
    params =
      case Schema.strict?(opts) do
        _strict? -> Schema.params(tool, [])
      end

    %{
      "name" => tool.name,
      "description" => tool.description || tool.name,
      "parameters" => convert(params, tool)
    }
  end

  defp convert(%{"$defs" => _defs}, tool), do: raise_ref(tool)
  defp convert(%{"$ref" => _ref}, tool), do: raise_ref(tool)

  defp convert(schema, tool) when is_map(schema) do
    schema
    |> drop_unsupported()
    |> normalize_type()
    |> normalize_enum()
    |> collapse_nullable(tool)
    |> put_items()
    |> convert_children(tool)
  end

  defp drop_unsupported(schema), do: Map.drop(schema, ["additionalProperties", "prefixItems"])

  defp normalize_type(%{"type" => types} = schema) when is_list(types) do
    non_null = Enum.reject(types, &(&1 == "null"))

    schema =
      case non_null do
        [type] -> Map.put(schema, "type", String.upcase(type))
        _other -> Map.delete(schema, "type")
      end

    if length(non_null) < length(types), do: Map.put(schema, "nullable", true), else: schema
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

  defp collapse_nullable(%{"anyOf" => branches} = schema, tool) when is_list(branches) do
    {nulls, rest} = Enum.split_with(branches, &null_schema?/1)
    schema = Map.put(schema, "anyOf", Enum.map(rest, &convert(&1, tool)))

    if nulls == [], do: schema, else: Map.put(schema, "nullable", true)
  end

  defp collapse_nullable(schema, _tool), do: schema

  defp null_schema?(%{"type" => "null"}), do: true
  defp null_schema?(_schema), do: false

  defp put_items(%{"type" => "ARRAY"} = schema), do: Map.put_new(schema, "items", %{})
  defp put_items(schema), do: schema

  defp convert_children(schema, tool) do
    schema =
      case schema do
        %{"properties" => properties} when is_map(properties) ->
          Map.put(
            schema,
            "properties",
            Map.new(properties, fn {name, property} -> {name, convert(property, tool)} end)
          )

        _other ->
          schema
      end

    case schema do
      %{"items" => %{} = items} -> Map.put(schema, "items", convert(items, tool))
      _other -> schema
    end
  end

  defp raise_ref(tool) do
    raise ArgumentError,
          "Gemini function parameters cannot express `$ref`/`$defs`; " <>
            "#{inspect(tool.name)} uses a recursive type. Use a non-recursive parameter, " <>
            "or send `parametersJsonSchema` yourself."
  end
end
