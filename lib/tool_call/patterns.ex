defmodule ToolCall.Patterns do
  @moduledoc false

  @char "^[\\s\\S]$"
  @regexes %{@char => Regex.compile!(@char, "u")}

  @doc false
  def char, do: @char

  @doc false
  def regex(pattern), do: Map.get(@regexes, pattern)
end
