# reach:disable-for-this-file string_building
# $defs names are short-lived compile-time labels; iolists would obscure them
# without a runtime benefit.
defmodule ToolCall.LocalTypeAlgorithm.AstAdapter do
  @moduledoc """
  AST adapter for `ToolCall.LocalTypeAlgorithm`.

  It preserves the legacy typespec AST operations used by local `@type`,
  `@typep`, and `@opaque` expansion, including `$defs` naming and metadata
  stripping.
  """

  @behaviour ToolCall.LocalTypeAlgorithm.Adapter

  @impl true
  def local_call({name, _meta, args}) when is_atom(name) and is_list(args),
    do: {:ok, {name, length(args)}, args}

  def local_call(_node), do: :error

  @impl true
  def children({_name, _meta, args}) when is_list(args), do: args
  def children({left, right}), do: [left, right]
  def children(list) when is_list(list), do: list
  def children(_node), do: []

  @impl true
  def put_children({name, meta, _children}, children) when is_list(children),
    do: {name, meta, children}

  def put_children({_left, _right}, [left, right]), do: {left, right}
  def put_children(list, children) when is_list(list), do: children
  def put_children(node, _children), do: node

  @impl true
  def substitute(body, [], _args), do: body

  def substitute(body, params, args) do
    bindings =
      params
      |> Enum.map(&var_name/1)
      |> Enum.zip(args)
      |> Map.new()

    Macro.prewalk(body, fn
      {name, _meta, context} = node when is_atom(name) and is_atom(context) ->
        Map.get(bindings, name, node)

      node ->
        node
    end)
  end

  @impl true
  def referenced_keys(ast, definitions) do
    {_ast, keys} =
      Macro.prewalk(ast, [], fn
        {name, _meta, args} = node, acc when is_atom(name) and is_list(args) ->
          key = {name, length(args)}
          if Map.has_key?(definitions, key), do: {node, [key | acc]}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    MapSet.new(keys)
  end

  @impl true
  def ref(index), do: {{:., [], [:tool_call_ref, :ref]}, [], [index]}

  @impl true
  def rewrite_refs(ast, names) when map_size(names) == 0, do: ast

  def rewrite_refs(ast, names) do
    Macro.prewalk(ast, fn
      {{:., _, [:tool_call_ref, :ref]}, meta, [index]} when is_integer(index) ->
        {{:., [], [:tool_call_ref, :ref]}, meta, [Map.fetch!(names, index)]}

      node ->
        node
    end)
  end

  @impl true
  def strip_meta(ast) do
    Macro.prewalk(ast, fn
      {name, _meta, args} -> {name, [], args}
      node -> node
    end)
  end

  @impl true
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

  defp arg_name({name, _, _}) when name in [:non_neg_integer, :pos_integer, :neg_integer, :byte],
    do: "integer"

  defp arg_name({:integer, _, _}), do: "integer"
  defp arg_name({:.., _, _}), do: "integer"
  defp arg_name(int) when is_integer(int), do: "integer"
  defp arg_name({:number, _, _}), do: "number"
  defp arg_name({:float, _, _}), do: "number"

  defp arg_name({name, _, _})
       when name in [
              :string,
              :binary,
              :bitstring,
              :charlist,
              :char,
              :nonempty_string,
              :nonempty_binary
            ],
       do: "string"

  defp arg_name({:boolean, _, _}), do: "boolean"
  defp arg_name({:atom, _, _}), do: "atom"
  defp arg_name({:term, _, _}), do: "any"
  defp arg_name({:any, _, _}), do: "any"
  defp arg_name({:list, _, [inner]}), do: "list_" <> arg_name(inner)
  defp arg_name([inner]), do: "list_" <> arg_name(inner)
  defp arg_name({:nonempty_list, _, [inner]}), do: "list_" <> arg_name(inner)
  defp arg_name({:map, _, _}), do: "map"
  defp arg_name({:%{}, _, _}), do: "map"
  defp arg_name({:{}, _, _}), do: "tuple"
  defp arg_name({_left, _right}), do: "tuple"
  defp arg_name({:|, _, [left, right]}), do: arg_name(left) <> "_or_" <> arg_name(right)

  defp arg_name({{:., _, [module, function]}, _, _args}) when is_atom(module) do
    base = module |> Module.split() |> List.last() |> String.downcase()
    if function == :t, do: base, else: base <> "_" <> Atom.to_string(function)
  end

  defp arg_name({:%, _, [module, {:%{}, _, _}]}) when is_atom(module),
    do: module |> Module.split() |> List.last() |> String.downcase()

  defp arg_name(atom) when is_atom(atom) and atom not in [true, false, nil],
    do: Atom.to_string(atom)

  defp arg_name(_other), do: "any"

  @doc false
  def var_name({name, _, context}) when is_atom(name) and is_atom(context), do: name
  def var_name(other), do: other
end
