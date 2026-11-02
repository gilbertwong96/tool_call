defmodule ToolCall.Patterns do
  @moduledoc false

  @char "^.$"
  @regexes %{@char => Regex.compile!(@char)}

  @doc false
  def char, do: @char

  @doc false
  def regex(pattern), do: Map.get(@regexes, pattern)
end
