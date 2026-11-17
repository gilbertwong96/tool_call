defmodule ToolCall.Patterns do
  @moduledoc "Shared regex patterns used by type mapping and coercion."

  @char "^[\\s\\S]$"
  @nonempty "^[\\s\\S]+$"
  @regexes %{
    @char => Regex.compile!(@char, "u"),
    @nonempty => Regex.compile!(@nonempty, "u")
  }

  @doc false
  def char, do: @char

  @doc false
  def nonempty, do: @nonempty

  @doc false
  def regex(pattern), do: Map.get(@regexes, pattern)
end
