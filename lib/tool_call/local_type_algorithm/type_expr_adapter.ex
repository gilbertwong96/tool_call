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
  def local_call({:ref, {name, arity}, args, _source_args}),
    do: {:ok, {name, arity}, args}

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
  def name(key, _args, {:ref, key, _node_args, source_args}) do
    AstAdapter.name(key, source_args)
  end

  def name(key, args, _node), do: AstAdapter.name(key, args)

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
        {:ref, key, _args, _source} ->
          if Map.has_key?(definitions, key), do: MapSet.put(keys, key), else: keys

        _other ->
          keys
      end

    Enum.reduce(TypeExpr.children(node), keys, fn child, keys ->
      collect(child, definitions, keys)
    end)
  end
end
