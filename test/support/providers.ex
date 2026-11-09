defmodule ToolCall.TestFixtures.ValidatingProvider do
  @moduledoc false
  @behaviour ToolCall.TypeProvider

  @impl true
  def resolve(ToolCall.TestFixtures.ValidateModule, :t, []),
    do: {:ok, %ToolCall.IR.Type{kind: :string}}

  def resolve(_module, _function, _args), do: :error

  @impl true
  def validate(value), do: is_binary(value)
end

defmodule ToolCall.TestFixtures.EmbedProvider do
  @moduledoc false
  @behaviour ToolCall.TypeProvider

  @impl true
  def resolve(ToolCall.TestFixtures.EmbedModule, :t, [inner]),
    do: {:ok, %ToolCall.IR.Type{kind: :array, items: inner}}

  def resolve(_module, _function, _args), do: :error
end
