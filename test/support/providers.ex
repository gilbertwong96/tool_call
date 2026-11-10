defmodule ToolCall.TestFixtures.ValidatingProvider do
  @moduledoc false
  @behaviour ToolCall.TypeProvider

  @impl true
  def resolve(ToolCall.TestFixtures.ValidateModule, :t, []),
    do: {:ok, %ToolCall.IR.Type{kind: :string}}

  def resolve(_module, _function, _args), do: :error

  @impl true
  def validate(_type, value, _defs), do: is_binary(value)
end

defmodule ToolCall.TestFixtures.EmbedProvider do
  @moduledoc false
  @behaviour ToolCall.TypeProvider

  @impl true
  def resolve(ToolCall.TestFixtures.EmbedModule, :t, [inner]),
    do: {:ok, %ToolCall.IR.Type{kind: :array, items: inner}}

  def resolve(_module, _function, _args), do: :error
end

defmodule ToolCall.TestFixtures.RejectAll do
  @moduledoc false
  def validate(_type, _value, _defs), do: false
end

defmodule ToolCall.TestFixtures.PrecedenceProvider do
  @moduledoc false
  @behaviour ToolCall.TypeProvider

  @impl true
  def resolve(ToolCall.TestFixtures.PrecedenceModule, :t, []) do
    {:ok,
     %ToolCall.IR.Type{
       kind: :string,
       validator: {ToolCall.TestFixtures.RejectAll, :validate}
     }}
  end

  def resolve(_module, _function, _args), do: :error

  @impl true
  def validate(_type, _value, _defs), do: true
end
