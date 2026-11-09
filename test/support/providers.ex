defmodule ToolCall.TestFixtures.EmbedProvider do
  @moduledoc false
  @behaviour ToolCall.TypeProvider

  @impl true
  def resolve(ToolCall.TestFixtures.EmbedModule, :t, [inner]),
    do: {:ok, %ToolCall.IR.Type{kind: :array, items: inner}}

  def resolve(_module, _function, _args), do: :error
end
