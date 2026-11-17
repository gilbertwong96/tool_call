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

  alias ToolCall.LocalTypeAlgorithm.RefName

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
  def strip_meta(ast), do: ToolCall.TypeAst.strip_meta(ast)

  @impl true
  def name(key, args), do: RefName.from_ast(key, args)

  @doc false
  def var_name({name, _, context}) when is_atom(name) and is_atom(context), do: name
  def var_name(other), do: other
end
