defmodule ToolCall.Providers.MapSet do
  @moduledoc false
  # `MapSet.t/0` and `MapSet.t/1` are public types whose only field (`map`) is
  # internal representation. A set travels as an array of its elements, and
  # dispatch rebuilds it with `MapSet.new/1`.

  @behaviour ToolCall.TypeProvider

  alias ToolCall.IR.Type

  @impl true
  def resolve(MapSet, :t, []), do: {:ok, array(%Type{kind: :any})}
  def resolve(MapSet, :t, [element]), do: {:ok, array(element)}
  def resolve(_module, _function, _args), do: :error

  @impl true
  def validate(%ToolCall.IR.Type{items: items}, %MapSet{} = value, defs) do
    Enum.all?(MapSet.to_list(value), &element_valid?(items, &1, defs))
  end

  def validate(_type, _value, _defs), do: false

  defp element_valid?(nil, _item, _defs), do: true
  defp element_valid?(%ToolCall.IR.Type{kind: :any}, _item, _defs), do: true

  defp element_valid?(%ToolCall.IR.Type{} = type, item, defs),
    do: ToolCall.Validate.valid?(type, item, defs) == :ok

  @impl true
  def coerce(values) when is_list(values), do: {:ok, MapSet.new(values)}
  def coerce(other), do: {:error, {:expected_array, other}}

  defp array(element) do
    %Type{kind: :array, items: element, source: {MapSet, :t}}
  end
end
