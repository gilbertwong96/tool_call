defmodule ToolCall.LocalTypes do
  @moduledoc false
  # Inlines `@type`, `@typep` and `@opaque` definitions declared in the module
  # being compiled, so that `@spec f(x :: my_type())` produces a real schema
  # instead of degrading to `:any`.
  #
  # Must run inside `@before_compile`: `Module.get_attribute/2` is only
  # readable while the module is still open.
  #
  # Two things stop the inlining of a non-cyclic type:
  #
  #   * recursion, detected per path (defensive; cyclic types are never
  #     inlined), and
  #   * a budget on the number of inlinings, because a hierarchy such as
  #     `@type t0 :: {t1(), t1()}` with `t1` doubling again grows as 2^depth.
  #     Measured: depth 16 is 16 s, depth 18 is 83 s. Past the budget the
  #     reference is left alone and degrades to `:any` further down.
  #
  # A cyclic type is emitted once as a `$defs` entry and referenced by `$ref` at
  # every occurrence. Two bounds keep a parameterized cycle
  # (`@type t(a) :: %{next: t({a, a})}`) finite: one per key and one overall.
  # Past either bound the reference degrades to `:any` and the compile warns.

  @max_inlinings 100
  @max_defs 32
  @max_instantiations_per_key 8

  @typedoc "One hoisted `$defs` entry, with the arguments of its instantiation."
  @type instantiation :: %{
          key: {atom(), non_neg_integer()},
          args: [term()],
          body: term()
        }

  @doc """
  Expands local type references in `ast`.

  A call whose key is cyclic (see `cyclic_keys/1`) is never inlined; it becomes
  a reference to a hoisted instantiation. Returns
  `{ast, truncated?, instantiations}`, where `truncated?` says that one of the
  budgets was hit and part of the type was left unresolved.

  An instantiation is referenced in the returned AST by the reserved remote
  call `{:., [], [:tool_call_ref, :ref]}` applied to its index in
  `instantiations`. Use `rewrite_refs/2` to replace those indices with final
  `$defs` names.
  """
  @spec expand(term(), module() | map()) :: {term(), boolean(), [instantiation()]}
  def expand(ast, module) when is_atom(module), do: expand(ast, definitions(module))

  def expand(ast, definitions) when is_map(definitions) do
    state = %{
      count: 0,
      truncated?: false,
      cyclic: cyclic_keys(definitions),
      insts: %{},
      by_inst: %{},
      per_key: %{}
    }

    {ast, state} = walk(ast, [], definitions, state)
    insts = state.insts |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))

    {ast, state.truncated?, insts}
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
    definitions
    |> Map.new(fn {key, {_params, body}} -> {key, referenced_keys(body, definitions)} end)
    |> ToolCall.Graph.cyclic_keys()
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

  @doc false
  @spec rewrite_refs(term(), %{non_neg_integer() => String.t()}) :: term()
  def rewrite_refs(ast, names) when map_size(names) == 0, do: ast

  def rewrite_refs(ast, names) do
    Macro.prewalk(ast, fn
      {{:., _, [:tool_call_ref, :ref]}, meta, [index]} when is_integer(index) ->
        {{:., [], [:tool_call_ref, :ref]}, meta, [Map.fetch!(names, index)]}

      node ->
        node
    end)
  end

  @doc false
  @spec name({atom(), non_neg_integer()}, [term()]) :: String.t()
  def name({type_name, _arity} = key, args) do
    name =
      case Enum.map(args, &arg_name/1) do
        [] ->
          Atom.to_string(type_name)

        parts ->
          # The suffix is a pure function of the instantiation, so adding a
          # parameter can never rename an existing `$defs` entry.
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

  defp walk({name, meta, args}, seen, definitions, state)
       when is_atom(name) and is_list(args) do
    key = {name, length(args)}

    case Map.fetch(definitions, key) do
      {:ok, {params, body}} ->
        cond do
          MapSet.member?(state.cyclic, key) ->
            hoist(key, {name, meta, args}, {params, body}, seen, definitions, state)

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

  defp hoist(key, node, {params, body}, seen, definitions, state) do
    args = node |> elem(2) |> strip_meta()
    inst = {key, args}

    case Map.fetch(state.by_inst, inst) do
      {:ok, index} ->
        {ref(index), state}

      :error ->
        if capped?(state, key) do
          {node, %{state | truncated?: true}}
        else
          index = map_size(state.insts)

          state = %{
            state
            | insts: Map.put(state.insts, index, %{key: key, args: args, body: nil}),
              by_inst: Map.put(state.by_inst, inst, index),
              per_key: Map.update(state.per_key, key, 1, &(&1 + 1))
          }

          {expanded, state} =
            body
            |> substitute(params, args)
            |> walk([key | seen], definitions, state)

          entry = %{key: key, args: args, body: expanded}
          {ref(index), %{state | insts: Map.put(state.insts, index, entry)}}
        end
    end
  end

  defp capped?(state, key) do
    map_size(state.insts) >= @max_defs or
      Map.get(state.per_key, key, 0) >= @max_instantiations_per_key
  end

  defp ref(index), do: {{:., [], [:tool_call_ref, :ref]}, [], [index]}

  defp strip_meta(ast) do
    Macro.prewalk(ast, fn
      {name, _meta, args} -> {name, [], args}
      node -> node
    end)
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
