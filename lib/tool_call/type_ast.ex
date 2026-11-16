defmodule ToolCall.TypeAst do
  @moduledoc false

  @doc false
  @spec substitute_vars(term(), %{atom() => term()}) :: term()
  def substitute_vars({name, _meta, context} = node, bindings)
      when is_atom(name) and is_atom(context) do
    Map.get(bindings, name, node)
  end

  def substitute_vars({left, right}, bindings),
    do: {substitute_vars(left, bindings), substitute_vars(right, bindings)}

  def substitute_vars(list, bindings) when is_list(list),
    do: Enum.map(list, &substitute_vars(&1, bindings))

  def substitute_vars({head, meta, args}, bindings),
    do: {substitute_vars(head, bindings), meta, substitute_vars(args, bindings)}

  def substitute_vars(other, _bindings), do: other
end
