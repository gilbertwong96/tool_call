# reach:disable-for-this-file string_building
# $defs names are short-lived compile-time labels; iolists would obscure them
# without a runtime benefit.
defmodule ToolCall.LocalTypeAlgorithm.RefName do
  @moduledoc """
  Builds `$defs` names for a local type instantiation.

  The readable part comes from each adapter's argument naming; the terminal hash
  keeps two instantiations of the same type distinct and is a pure function of the
  type key and its arguments.
  """

  alias ToolCall.TypeExpr.Typespec, as: TypeExprTypespec

  @doc """
  Names an instantiation described by typespec AST arguments.

  Local type definitions arrive as AST, so this is the entry point for
  `ToolCall.Structs.Resolve` and `ToolCall.LocalTypes`; it converts each argument
  to `ToolCall.TypeExpr` first, which means AST and `TypeExpr` recursion produce
  the same hash for the same type.
  """
  @spec from_ast({atom(), non_neg_integer()}, [term()]) :: String.t()
  def from_ast(key, ast_args) do
    build(key, Enum.map(ast_args, &TypeExprTypespec.from_ast/1), &arg_name/1)
  end

  @doc false
  @spec arg_name(term()) :: String.t()
  def arg_name({:annotated, type, _metadata}), do: arg_name(type)
  def arg_name({:primitive, :integer}), do: "integer"
  def arg_name({:integer_range, _low, _high}), do: "integer"
  def arg_name({:primitive, :number}), do: "number"
  def arg_name({:primitive, :float}), do: "number"
  def arg_name({:literal, value}) when is_number(value), do: literal_arg_name(value)
  def arg_name({:primitive, :string}), do: "string"
  def arg_name({:string, _metadata}), do: "string"
  def arg_name({:primitive, :boolean}), do: "boolean"
  def arg_name({:primitive, :atom}), do: "atom"
  def arg_name({:list, inner}), do: "list_" <> arg_name(inner)
  def arg_name({:nonempty_list, inner}), do: "list_" <> arg_name(inner)
  def arg_name({:map, _fields, _additional}), do: "map"
  def arg_name({:tuple, _items}), do: "tuple"
  def arg_name({:union, variants}), do: Enum.map_join(variants, "_or_", &arg_name/1)
  def arg_name({:remote, module, :t, _args}), do: module_arg_name(module)

  def arg_name({:remote, module, function, _args}),
    do: module_arg_name(module) <> "_" <> Atom.to_string(function)

  def arg_name({:literal, value}) when is_atom(value) and value not in [true, false, nil],
    do: Atom.to_string(value)

  def arg_name(_other), do: "any"

  @doc false
  @spec build({atom(), non_neg_integer()}, [term()], (term() -> String.t())) :: String.t()
  def build({type_name, _arity} = key, args, arg_name_fun) do
    case Enum.map(args, arg_name_fun) do
      [] ->
        sanitize(Atom.to_string(type_name))

      parts ->
        sanitize(
          Atom.to_string(type_name) <>
            "_" <> Enum.join(parts, "_") <> "_" <> signature(key, args)
        )
    end
  end

  defp sanitize(name) do
    sanitized =
      name
      |> String.replace(~r/[^A-Za-z0-9_]/, "_")
      |> String.slice(0, 64)
      |> String.trim_trailing("_")

    if sanitized == "", do: "type", else: sanitized
  end

  defp literal_arg_name(value) when is_integer(value), do: "integer"
  defp literal_arg_name(value) when is_float(value), do: "number"

  defp module_arg_name(module) do
    module |> Module.split() |> List.last() |> String.downcase()
  end

  defp signature(key, args) do
    key
    |> then(&{&1, args})
    |> :erlang.phash2()
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.slice(0, 4)
  end
end
