defmodule ToolCall.TypeExpr.TypespecParityTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ToolCall.IR.Type
  alias ToolCall.{TypeExpr, Typespec}

  # Every construct here is mapped twice: once by the legacy typespec mapper and
  # once through `TypeExpr` -> `TypeExpr.Compiler`. The two must agree, because a
  # divergence silently changes whether a tool is exposed and what the model sees.
  @cases [
    "integer()",
    "non_neg_integer()",
    "pos_integer()",
    "neg_integer()",
    "byte()",
    "float()",
    "number()",
    "boolean()",
    "atom()",
    "module()",
    "binary()",
    "bitstring()",
    "string()",
    "charlist()",
    "char()",
    "nonempty_binary()",
    "nonempty_string()",
    "list()",
    "list(integer())",
    "nonempty_list()",
    "nonempty_list(integer())",
    "keyword()",
    "keyword(integer())",
    "map()",
    "struct()",
    "tuple()",
    "{}",
    "term()",
    "any()",
    "as_boolean(integer())",
    "as_boolean()",
    "fun()",
    "fun((integer() -> integer()))",
    "pid()",
    "port()",
    "reference()",
    "mfa()",
    "no_return()",
    "none()",
    "1..10",
    "{:.., [], [{:x, [], nil}, 2]}",
    "-5",
    "~c\"abc\"",
    "\"literal\"",
    ":atom_literal",
    "%{a: integer()}",
    "%{optional(:b) => integer()}",
    "%{String.t() => integer()}",
    "[integer()]",
    "[integer(), ...]",
    "{integer(), String.t()}",
    "{integer(), integer(), integer()}",
    "Date.t()",
    "Time.t()",
    "DateTime.t()",
    "NaiveDateTime.t()",
    "String.t()",
    "Path.t()",
    "MapSet.t()",
    "MapSet.t(integer())",
    "Regex.t()",
    "Some.Unknown.t()",
    "Some.Unknown.t(integer())",
    "iolist()",
    "iodata()",
    "maybe_improper_list()",
    "nonempty_improper_list()",
    "1 | 2",
    "integer() | String.t()",
    "nil | integer()",
    "true | false",
    ":a | :b",
    "integer() | nil | String.t()"
  ]

  defp quoted(source) do
    source
    |> Code.string_to_quoted!()
    |> Macro.prewalk(&Macro.expand(&1, __ENV__))
  end

  test "every supported construct maps to the same IR through both paths" do
    for source <- @cases do
      ast = quoted(source)

      legacy = ast |> Typespec.to_type(Typespec.builtin_providers()) |> normalize()
      compiled = compile(ast) |> normalize()

      assert legacy == compiled, """
      #{source} diverged between the legacy mapper and the TypeExpr pipeline:
        legacy:   #{inspect(legacy)}
        compiled: #{inspect(compiled)}
      """
    end
  end

  defp compile(ast) do
    ast
    |> TypeExpr.Typespec.from_ast()
    |> TypeExpr.Compiler.to_type(Typespec.builtin_providers())
  end

  # Provenance, compiled patterns, and provider closures legitimately differ
  # between the two paths; the value domain and wire shape must not.
  defp normalize(%Type{} = type) do
    %{
      type
      | source: nil,
        pattern_regex: nil,
        items: normalize_items(type.items),
        fields: normalize_fields(type.fields),
        variants: normalize_list(type.variants),
        additional: normalize_type(type.additional)
    }
  end

  defp normalize(other), do: other

  defp normalize_type(nil), do: nil
  defp normalize_type(%Type{} = type), do: normalize(type)

  defp normalize_items(nil), do: nil
  defp normalize_items(list) when is_list(list), do: Enum.map(list, &normalize_type/1)
  defp normalize_items(type), do: normalize_type(type)

  defp normalize_fields(nil), do: nil

  defp normalize_fields(fields),
    do: Enum.map(fields, fn field -> %{field | type: normalize_type(field.type)} end)

  defp normalize_list(nil), do: nil
  defp normalize_list(list), do: Enum.map(list, &normalize_type/1)
end
