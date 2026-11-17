defmodule ToolCall.Diagnostic do
  @moduledoc """
  A structured compile-time diagnostic returned by a function-declaration source.

  The message is rendered by the builder at the definition location;
  severity leaves room for future sources to distinguish warnings from errors.
  """

  defstruct [:severity, :message]

  @type severity :: :warning | :error
  @type t :: %__MODULE__{severity: severity(), message: String.t()}

  @spec warning(String.t()) :: t()
  def warning(message) when is_binary(message) do
    %__MODULE__{severity: :warning, message: message}
  end

  @spec error(String.t()) :: t()
  def error(message) when is_binary(message) do
    %__MODULE__{severity: :error, message: message}
  end

  @spec message(t()) :: String.t()
  def message(%__MODULE__{message: message}), do: message
end
