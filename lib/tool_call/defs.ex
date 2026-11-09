defmodule ToolCall.Defs do
  @moduledoc false
  # Which `$defs` entries a set of types actually reaches. The emitter renders
  # only these, and the builder warns only about these: a definition referenced
  # solely by a result type never reaches the model.

  alias ToolCall.IR.Type

  @spec reachable([Type.t()], %{String.t() => Type.t()}) :: MapSet.t(String.t())
  def reachable(types, defs) when is_map(defs) do
    walk_all(types, defs, MapSet.new())
  end

  defp walk_all(types, defs, seen) do
    Enum.reduce(types, seen, fn type, seen -> walk(type, defs, seen) end)
  end

  defp walk(%Type{kind: :ref, ref: ref}, defs, seen) do
    if MapSet.member?(seen, ref) do
      seen
    else
      seen = MapSet.put(seen, ref)

      case Map.fetch(defs, ref) do
        {:ok, target} -> walk(target, defs, seen)
        :error -> seen
      end
    end
  end

  defp walk(%Type{kind: :object} = type, defs, seen) do
    seen = walk(type.additional, defs, seen)
    Enum.reduce(type.fields || [], seen, fn field, seen -> walk(field.type, defs, seen) end)
  end

  defp walk(%Type{kind: :array} = type, defs, seen), do: walk(type.items, defs, seen)

  defp walk(%Type{kind: :tuple} = type, defs, seen),
    do: walk_all(type.items || [], defs, seen)

  defp walk(%Type{kind: :union} = type, defs, seen),
    do: walk_all(type.variants || [], defs, seen)

  defp walk(nil, _defs, seen), do: seen
  defp walk(%Type{}, _defs, seen), do: seen
end
