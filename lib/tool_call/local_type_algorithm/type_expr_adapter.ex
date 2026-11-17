# reach:disable-for-this-file string_building
# $defs names are short-lived compile-time labels; iolists would obscure them
# without a runtime benefit.
defmodule ToolCall.LocalTypeAlgorithm.TypeExprAdapter do
  @moduledoc """
  `ToolCall.TypeExpr` adapter for `ToolCall.LocalTypeAlgorithm`.

  Parameterized local references keep their source AST arguments as provenance,
  so `$defs` names stay identical to the typespec-AST expansion.
  """

  @behaviour ToolCall.LocalTypeAlgorithm.Adapter

  alias ToolCall.{LocalTypeAlgorithm, TypeExpr}
  alias ToolCall.LocalTypeAlgorithm.AstAdapter

  @impl true
  def local_call({:ref, {name, arity}, args}), do: {:ok, {name, arity}, args}

  def local_call(_node), do: :error

  @impl true
  def children(node), do: TypeExpr.children(node)

  @impl true
  def put_children(node, children), do: TypeExpr.put_children(node, children)

  @impl true
  def substitute(node, params, args) do
    bindings =
      params
      |> Enum.map(&AstAdapter.var_name/1)
      |> Enum.zip(args)
      |> Map.new()

    map(node, fn
      {:var, name} -> Map.get(bindings, name, {:var, name})
      other -> other
    end)
  end

  @impl true
  def referenced_keys(node, definitions), do: collect(node, definitions, MapSet.new())

  @impl true
  def ref(index), do: {:local_ref, index}

  @impl true
  def rewrite_refs(node, names) when map_size(names) == 0, do: node

  def rewrite_refs(node, names) do
    map(node, fn
      {:local_ref, index} -> {:ref, Map.fetch!(names, index)}
      other -> other
    end)
  end

  @impl true
  def strip_meta(node), do: node

  @impl true
  def name(key, args, _node), do: name(key, args)

  @doc false
  def name({type_name, _arity} = key, args) do
    name =
      case Enum.map(args, &arg_name/1) do
        [] ->
          Atom.to_string(type_name)

        parts ->
          Atom.to_string(type_name) <>
            "_" <> Enum.join(parts, "_") <> "_" <> signature(key, args)
      end

    sanitized =
      name
      |> String.replace(~r/[^A-Za-z0-9_]/, "_")
      |> String.slice(0, 64)
      |> String.trim_trailing("_")

    if sanitized == "", do: "type", else: sanitized
  end

  defp signature(key, args) do
    key
    |> then(&{&1, args})
    |> :erlang.phash2()
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.slice(0, 4)
  end

  defp arg_name({:annotated, type, _metadata}), do: arg_name(type)
  defp arg_name({:primitive, :integer}), do: "integer"
  defp arg_name({:integer_range, _low, _high}), do: "integer"
  defp arg_name({:primitive, :number}), do: "number"
  defp arg_name({:primitive, :float}), do: "number"
  defp arg_name({:literal, value}) when is_number(value), do: arg_name_type(value)
  defp arg_name({:primitive, :string}), do: "string"
  defp arg_name({:string, _metadata}), do: "string"
  defp arg_name({:primitive, :boolean}), do: "boolean"
  defp arg_name({:primitive, :atom}), do: "atom"
  defp arg_name({:list, inner}), do: "list_" <> arg_name(inner)
  defp arg_name({:nonempty_list, inner}), do: "list_" <> arg_name(inner)
  defp arg_name({:map, _fields, _additional}), do: "map"
  defp arg_name({:tuple, _items}), do: "tuple"

  defp arg_name({:union, variants}),
    do: Enum.map_join(variants, "_or_", &arg_name/1)

  defp arg_name({:remote, module, :t, _args}), do: module_arg_name(module)

  defp arg_name({:remote, module, function, _args}),
    do: module_arg_name(module) <> "_" <> Atom.to_string(function)

  defp arg_name({:literal, value}) when is_atom(value) and value not in [true, false, nil],
    do: Atom.to_string(value)

  defp arg_name(_other), do: "any"

  defp arg_name_type(value) when is_integer(value), do: "integer"
  defp arg_name_type(value) when is_float(value), do: "number"

  defp module_arg_name(module) do
    module |> Module.split() |> List.last() |> String.downcase()
  end

  @doc false
  def expand(root, definitions, opts \\ []) do
    LocalTypeAlgorithm.expand(root, definitions, __MODULE__, opts)
  end

  defp map(node, fun) do
    node = fun.(node)
    children = Enum.map(TypeExpr.children(node), &map(&1, fun))
    TypeExpr.put_children(node, children)
  end

  defp collect(node, definitions, keys) do
    keys =
      case node do
        {:ref, key, _args} ->
          if Map.has_key?(definitions, key), do: MapSet.put(keys, key), else: keys

        _other ->
          keys
      end

    Enum.reduce(TypeExpr.children(node), keys, fn child, keys ->
      collect(child, definitions, keys)
    end)
  end
end
