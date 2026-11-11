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

  The child id is `ToolCall.PolicyValidation`: use one child per supervisor with
  the complete module list. Validation runs synchronously during supervisor
  start, before later children start; it is not repeated by supervisor restarts.
  """

  @doc """
  Returns the one-shot child specification.

  The id is fixed (`ToolCall.PolicyValidation`); use one child per supervisor
  with the complete module list.
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

  @doc """
  Validates each module and returns `:ignore`.

  This runs synchronously during the supervisor's child start. An invalid policy
  raises `ArgumentError`.
  """
  @spec start_link([module()] | module()) :: :ignore
  def start_link(modules) when is_list(modules) do
    Enum.each(modules, &ToolCall.validate_policies!/1)
    :ignore
  end

  def start_link(module), do: start_link([module])
end
