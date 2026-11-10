defmodule ToolCall.Timeout do
  @moduledoc """
  Per-invocation timeouts and the timeout policy behaviour.

  `run/3` executes a zero-arity function in a task and answers
  `{:error, {:timeout, ms}}` when it does not finish in time. The task is
  killed with `:brutal_kill`; it is **not** a cancellation: the function may
  already have produced its side effect. A tool that owns resources or relies
  on the caller's process (`self/0`, the process dictionary, Ecto sandbox
  ownership) should use a cooperative timeout instead.

  A module implementing `timeout/3` can be passed to
  `use ToolCall, timeout: MyPolicy`; `ToolCall.run/4` with `timeout: ms` wins
  over the policy.
  """

  alias ToolCall.IR.Tool

  @callback timeout(Tool.t(), map(), term()) :: timeout()

  @doc """
  Runs `fun` with a timeout.

  Options:

    * `:task_supervisor` - a `Task.Supervisor` name. Without it the task is
      linked to the caller; with it the task is started under the supervisor.
  """
  @spec run((-> term()), timeout(), keyword()) :: term()
  def run(fun, :infinity, _opts), do: fun.()

  def run(fun, timeout, opts) when is_integer(timeout) and timeout >= 0 do
    task = start_task(fun, opts)

    case Task.yield(task, timeout) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:exited, reason}}
      nil -> shutdown_task(Task.shutdown(task, :brutal_kill), timeout)
    end
  end

  def run(_fun, timeout, _opts) do
    raise ArgumentError,
          "timeout must be :infinity or a non-negative integer, got: #{inspect(timeout)}"
  end

  defp start_task(fun, opts) do
    case Keyword.get(opts, :task_supervisor) do
      nil -> Task.async(fun)
      supervisor -> Task.Supervisor.async_nolink(supervisor, fun)
    end
  end

  defp shutdown_task({:ok, result}, _timeout), do: result
  defp shutdown_task({:exit, reason}, _timeout), do: {:error, {:exited, reason}}
  defp shutdown_task(nil, timeout), do: {:error, {:timeout, timeout}}

  @doc false
  @spec validate!(term()) :: timeout()
  def validate!(:infinity), do: :infinity
  def validate!(timeout) when is_integer(timeout) and timeout >= 0, do: timeout

  def validate!(other) do
    raise ArgumentError,
          "timeout must be :infinity or a non-negative integer, got: #{inspect(other)}"
  end
end
