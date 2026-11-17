defmodule ToolCall.Diagnostic do
  @moduledoc """
  A structured compile-time diagnostic returned by a function-declaration source.

  `line` and `column` point at the declaration that produced the diagnostic, such
  as the `@spec` line, and are optional: a source that cannot locate its input
  leaves them `nil` and the builder falls back to the definition location.

  `severity` decides what the builder does with it: `:warning` is reported and
  the affected tool is skipped, `:error` fails the compile.
  """

  defstruct [:severity, :message, :line, :column]

  @type severity :: :warning | :error

  @type location :: [{:line, pos_integer()} | {:column, pos_integer()}]

  @type t :: %__MODULE__{
          severity: severity(),
          message: String.t(),
          line: pos_integer() | nil,
          column: pos_integer() | nil
        }

  @spec warning(String.t(), location()) :: t()
  def warning(message, location \\ []) when is_binary(message) do
    build(:warning, message, location)
  end

  @spec error(String.t(), location()) :: t()
  def error(message, location \\ []) when is_binary(message) do
    build(:error, message, location)
  end

  @doc "Returns the diagnostic's own `{line, column}`, or `nil` when unknown."
  @spec position(t()) :: {pos_integer() | nil, pos_integer() | nil} | nil
  def position(%__MODULE__{line: nil}), do: nil
  def position(%__MODULE__{line: line, column: column}), do: {line, column}

  @spec message(t()) :: String.t()
  def message(%__MODULE__{message: message}), do: message

  defp build(severity, message, location) when is_list(location) do
    %__MODULE__{
      severity: severity,
      message: message,
      line: positive_or_nil(Keyword.get(location, :line)),
      column: positive_or_nil(Keyword.get(location, :column))
    }
  end

  defp positive_or_nil(value) when is_integer(value) and value > 0, do: value
  defp positive_or_nil(_value), do: nil
end
