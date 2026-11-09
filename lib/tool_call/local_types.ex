defmodule ToolCall.LocalTypes do
  @moduledoc false
  # Inlines `@type`, `@typep` and `@opaque` definitions declared in the module
  # being compiled, so that `@spec f(x :: my_type())` produces a real schema
  # instead of degrading to `:any`.
  #
  # Must run inside `@before_compile`: `Module.get_attribute/2` is only
  # readable while the module is still open.
  #
  # Two things stop the inlining:
  #
  #   * recursion, detected per path, and
  #   * a budget on the number of inlinings, because a hierarchy such as
  #     `@type t0 :: {t1(), t1()}` with `t1` doubling again grows as 2^depth.
  #     Measured: depth 16 is 16 s, depth 18 is 83 s. Past the budget the
  #     reference is left alone and degrades to `:any` further down.
  #
  # `$ref`/`$defs` would remove the need for both limits; see docs/design.md.

  @max_inlinings 100

  @doc """
  Expands local type references in `ast`.

  Returns `{ast, truncated?}` where `truncated?` says that the inlining budget
  was hit and part of the type was left unresolved.
  """
  @spec expand(term(), module() | map()) :: {term(), boolean()}
  def expand(ast, module) when is_atom(module), do: expand(ast, definitions(module))

  def expand(ast, definitions) when is_map(definitions) do
    {ast, state} = walk(ast, [], definitions, %{count: 0, truncated?: false})
    {ast, state.truncated?}
  end

  @doc false
  @spec definitions(module()) :: map()
  def definitions(module) do
    for attribute <- [:type, :typep, :opaque],
        {_kind, {:"::", _, [{name, _, params}, body]}, _location} <-
          List.wrap(Module.get_attribute(module, attribute)),
        is_atom(name),
        into: %{} do
      params = List.wrap(params)
      {{name, length(params)}, {params, body}}
    end
  end

  @doc false
  @spec cyclic_keys(map()) :: MapSet.t({atom(), non_neg_integer()})
  def cyclic_keys(definitions) when is_map(definitions) do
    edges =
      Map.new(definitions, fn {key, {_params, body}} ->
        {key, referenced_keys(body, definitions)}
      end)

    for key <- Map.keys(edges), cyclic?(edges, key), into: MapSet.new(), do: key
  end

  defp referenced_keys(ast, definitions) do
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

  defp cyclic?(edges, key) do
    Map.get(edges, key, MapSet.new())
    |> reachable(edges, MapSet.new())
    |> MapSet.member?(key)
  end

  defp reachable(frontier, edges, seen) do
    Enum.reduce(frontier, seen, fn node, seen ->
      if MapSet.member?(seen, node) do
        seen
      else
        reachable(Map.get(edges, node, MapSet.new()), edges, MapSet.put(seen, node))
      end
    end)
  end

  defp walk({name, meta, args}, seen, definitions, state)
       when is_atom(name) and is_list(args) do
    key = {name, length(args)}

    case Map.fetch(definitions, key) do
      {:ok, {params, body}} ->
        cond do
          key in seen ->
            {{name, meta, args}, state}

          state.count >= @max_inlinings ->
            {{name, meta, args}, %{state | truncated?: true}}

          true ->
            body
            |> substitute(params, args)
            |> walk([key | seen], definitions, %{state | count: state.count + 1})
        end

      :error ->
        {args, state} = walk_all(args, seen, definitions, state)
        {{name, meta, args}, state}
    end
  end

  # A remote call is `{{:., _, [Mod, :fun]}, _, args}`; its arguments may still
  # contain a local type, e.g. `Keyword.t(my_type())`.
  defp walk({head, meta, args}, seen, definitions, state) when is_list(args) do
    {args, state} = walk_all(args, seen, definitions, state)
    {{head, meta, args}, state}
  end

  defp walk({left, right}, seen, definitions, state) do
    {left, state} = walk(left, seen, definitions, state)
    {right, state} = walk(right, seen, definitions, state)
    {{left, right}, state}
  end

  defp walk(list, seen, definitions, state) when is_list(list) do
    walk_all(list, seen, definitions, state)
  end

  defp walk(other, _seen, _definitions, state), do: {other, state}

  defp walk_all(nodes, seen, definitions, state) do
    {reversed, state} =
      Enum.reduce(nodes, {[], state}, fn node, {acc, state} ->
        {node, state} = walk(node, seen, definitions, state)
        {[node | acc], state}
      end)

    {Enum.reverse(reversed), state}
  end

  @doc false
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

  @doc false
  @spec var_name(term()) :: term()
  def var_name({name, _, context}) when is_atom(name) and is_atom(context), do: name
  def var_name(other), do: other
end
