defmodule ToolCall.Patterns do
  @moduledoc false

  @char "^.$"
  @decimal "^-?\\d+(\\.\\d+)?([eE][+-]?\\d+)?$"

  @regexes %{
    @char => Regex.compile!(@char),
    @decimal => Regex.compile!(@decimal)
  }

  @doc false
  def char, do: @char

  @doc false
  def decimal, do: @decimal

  @doc false
  def regex(pattern), do: Map.get(@regexes, pattern)
end
