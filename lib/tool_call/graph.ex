defmodule ToolCall.Graph do
  @moduledoc false
  # Cyclicity over a `%{node => MapSet.t(node)}` edge map. A node is cyclic when
  # it can reach itself.

  @spec cyclic_keys(map()) :: MapSet.t(term())
  def cyclic_keys(edges) when is_map(edges) do
    for node <- Map.keys(edges), cyclic?(edges, node), into: MapSet.new(), do: node
  end

  defp cyclic?(edges, node) do
    edges
    |> Map.get(node, MapSet.new())
    |> reachable(edges, %{})
    |> Map.has_key?(node)
  end

  defp reachable(frontier, edges, seen) do
    Enum.reduce(frontier, seen, fn node, seen ->
      if Map.has_key?(seen, node) do
        seen
      else
        reachable(Map.get(edges, node, MapSet.new()), edges, Map.put(seen, node, true))
      end
    end)
  end
end
