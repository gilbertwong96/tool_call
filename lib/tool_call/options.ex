defmodule ToolCall.Options do
  @moduledoc false

  @spec validate!(keyword(), [atom()]) :: :ok
  def validate!(opts, allowed) do
    validate_keys!(opts, allowed)
    validate_validate_result!(opts)
    validate_timeout_policy!(opts)
    validate_task_supervisor!(opts)
    validate_approval!(opts)
    validate_audit!(opts)
    :ok
  end

  @spec validate_policy!(atom(), atom(), non_neg_integer(), String.t()) :: :ok
  def validate_policy!(policy, function, arity, label) do
    unless Code.ensure_loaded?(policy) and function_exported?(policy, function, arity) do
      raise ArgumentError,
            "#{label} policy #{inspect(policy)} does not export #{function}/#{arity}"
    end

    :ok
  end

  defp validate_keys!(opts, allowed) do
    case Keyword.keys(opts) -- allowed do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown options: #{inspect(unknown)}"
    end
  end

  defp validate_validate_result!(opts) do
    case Keyword.get(opts, :validate_result, false) do
      value when is_boolean(value) -> :ok
      other -> raise ArgumentError, "validate_result must be a boolean, got: #{inspect(other)}"
    end
  end

  defp validate_timeout_policy!(opts) do
    case Keyword.fetch(opts, :timeout_policy) do
      :error ->
        :ok

      {:ok, nil} ->
        :ok

      {:ok, timeout} when is_integer(timeout) ->
        :ok

      {:ok, :infinity} ->
        :ok

      {:ok, policy} when is_atom(policy) and policy not in [true, false] ->
        :ok

      {:ok, other} ->
        raise ArgumentError,
              "timeout_policy must be :infinity, a non-negative integer or a module, " <>
                "got: #{inspect(other)}"
    end
  end

  defp validate_task_supervisor!(opts) do
    case Keyword.get(opts, :task_supervisor) do
      nil ->
        :ok

      supervisor when is_atom(supervisor) or is_pid(supervisor) ->
        :ok

      other ->
        raise ArgumentError,
              "task_supervisor must be a supervisor name or pid, got: #{inspect(other)}"
    end
  end

  defp validate_approval!(opts) do
    case Keyword.get(opts, :approval) do
      nil ->
        :ok

      :granted ->
        :ok

      :denied ->
        :ok

      policy when is_atom(policy) and policy not in [true, false] ->
        validate_policy!(policy, :check, 3, "approval")

      other ->
        raise ArgumentError,
              "approval must be :granted, :denied, a module or nil, got: #{inspect(other)}"
    end
  end

  defp validate_audit!(opts) do
    case Keyword.get(opts, :audit) do
      nil ->
        :ok

      policy when is_atom(policy) and policy not in [true, false, :granted, :denied] ->
        validate_policy!(policy, :record, 1, "audit")

      other ->
        raise ArgumentError, "audit must be a module or nil, got: #{inspect(other)}"
    end
  end
end
