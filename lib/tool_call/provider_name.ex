defmodule ToolCall.ProviderName do
  @moduledoc false

  @pattern ~r/^[a-zA-Z0-9_-]{1,64}$/

  @doc false
  def valid?(name) when is_binary(name), do: Regex.match?(@pattern, name)
  def valid?(_name), do: false

  @doc false
  def pattern, do: @pattern
end
