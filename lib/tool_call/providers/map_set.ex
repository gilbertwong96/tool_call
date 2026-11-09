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
  def validate(value), do: is_struct(value, MapSet)

  @impl true
  def coerce(values) when is_list(values), do: {:ok, MapSet.new(values)}
  def coerce(other), do: {:error, {:expected_array, other}}

  defp array(element) do
    %Type{kind: :array, items: element, source: {MapSet, :t}}
  end
end
