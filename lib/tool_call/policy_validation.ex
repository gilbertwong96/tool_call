defmodule ToolCall.PolicyValidation do
  @moduledoc """
  A one-shot supervision-tree child that validates module-level policies at
  application startup.

  Add it before the processes that dispatch tool calls:

      children = [
        {ToolCall.PolicyValidation, [MyApp.Tools]},
        # ...
      ]

  Each module is checked with `ToolCall.validate_policies!/1`. The child returns
  `:ignore`, so it does not stay in the supervision tree. An invalid policy
  fails application startup with `ArgumentError`.
  """

  @spec child_spec([module()] | module()) :: %{
          id: module(),
          start: {module(), :start_link, [term()]},
          restart: :temporary,
          type: :worker
        }
  def child_spec(modules) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [modules]},
      restart: :temporary,
      type: :worker
    }
  end

  @spec start_link([module()] | module()) :: :ignore
  def start_link(modules) when is_list(modules) do
    Enum.each(modules, &ToolCall.validate_policies!/1)
    :ignore
  end

  def start_link(module), do: start_link([module])
end
