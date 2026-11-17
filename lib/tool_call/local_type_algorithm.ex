defmodule ToolCall.LocalTypeAlgorithm do
  @moduledoc """
  Shared local-type expansion algorithm used by AST and, later, `TypeExpr`.

  The algorithm owns cyclic detection, inlining and instantiation budgets,
  hoisting, and `$defs` naming. Adapters supply the node structure, variable
  substitution, reference syntax, and naming details.
  """

  defmodule Adapter do
    @moduledoc "Callbacks required by `ToolCall.LocalTypeAlgorithm`."

    @type key :: {atom(), non_neg_integer()}

    @callback local_call(term()) :: {:ok, key(), [term()]} | :error
    @callback children(term()) :: [term()]
    @callback put_children(term(), [term()]) :: term()
    @callback substitute(term(), [term()], [term()]) :: term()
    @callback referenced_keys(term(), map()) :: MapSet.t(key())
    @callback ref(non_neg_integer()) :: term()
    @callback rewrite_refs(term(), %{non_neg_integer() => String.t()}) :: term()
    @callback strip_meta(term()) :: term()
    @callback name(key(), [term()]) :: String.t()
  end

  alias ToolCall.LocalTypeAlgorithm.Adapter

  @typedoc "One hoisted `$defs` entry, with the arguments of its instantiation."
  @type instantiation :: %{
          key: Adapter.key(),
          args: [term()],
          body: term()
        }

  @max_inlinings 100
  @max_defs 32
  @max_instantiations_per_key 8

  @spec expand(term(), map(), module(), keyword()) :: {term(), boolean(), [instantiation()]}
  def expand(root, definitions, adapter, opts \\ []) do
    state = %{
      count: 0,
      truncated?: false,
      cyclic: Keyword.get_lazy(opts, :cyclic, fn -> cyclic_keys(definitions, adapter) end),
      max_defs: Keyword.get(opts, :max_defs, @max_defs),
      insts: %{},
      by_inst: %{},
      per_key: %{}
    }

    {root, state} = walk(root, [], definitions, adapter, state)
    insts = state.insts |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))

    {root, state.truncated?, insts}
  end

  @spec cyclic_keys(map(), module()) :: MapSet.t(Adapter.key())
  def cyclic_keys(definitions, adapter) when is_map(definitions) do
    definitions
    |> Map.new(fn {key, {_params, body}} ->
      {key, adapter.referenced_keys(body, definitions)}
    end)
    |> ToolCall.Graph.cyclic_keys()
  end

  @spec max_defs() :: pos_integer()
  def max_defs, do: @max_defs

  defp walk(node, seen, definitions, adapter, state) do
    case adapter.local_call(node) do
      {:ok, key, args} -> walk_local(key, args, node, seen, definitions, adapter, state)
      :error -> walk_children(node, seen, definitions, adapter, state)
    end
  end

  defp walk_local(key, args, node, seen, definitions, adapter, state) do
    case Map.fetch(definitions, key) do
      {:ok, definition} ->
        expand_local(key, args, node, definition, seen, definitions, adapter, state)

      :error ->
        walk_children(node, seen, definitions, adapter, state)
    end
  end

  defp expand_local(key, args, node, {params, body}, seen, definitions, adapter, state) do
    cond do
      MapSet.member?(state.cyclic, key) ->
        hoist(key, node, args, {params, body}, seen, definitions, adapter, state)

      key in seen ->
        {node, state}

      state.count >= @max_inlinings ->
        {node, %{state | truncated?: true}}

      true ->
        body
        |> adapter.substitute(params, args)
        |> walk([key | seen], definitions, adapter, %{state | count: state.count + 1})
    end
  end

  defp walk_children(node, seen, definitions, adapter, state) do
    {children, state} =
      Enum.map_reduce(adapter.children(node), state, fn child, state ->
        walk(child, seen, definitions, adapter, state)
      end)

    {adapter.put_children(node, children), state}
  end

  defp hoist(key, node, args, {params, body}, seen, definitions, adapter, state) do
    args = adapter.strip_meta(args)
    inst = {key, args}

    case Map.fetch(state.by_inst, inst) do
      {:ok, index} ->
        {adapter.ref(index), state}

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
            |> adapter.substitute(params, args)
            |> walk([key | seen], definitions, adapter, state)

          entry = %{key: key, args: args, body: expanded}

          {adapter.ref(index), %{state | insts: Map.put(state.insts, index, entry)}}
        end
    end
  end

  defp capped?(state, key) do
    map_size(state.insts) >= state.max_defs or
      Map.get(state.per_key, key, 0) >= @max_instantiations_per_key
  end
end
