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
  over the policy. `timeout/3` receives the tool IR, the validated and coerced
  argument map and the caller's context; it runs after argument validation, so
  a policy may rely on the declared argument types.
  """

  alias ToolCall.IR.Tool

  @callback timeout(Tool.t(), map(), term()) :: timeout()

  @doc """
  Runs `fun` with a timeout.

  Options:

    * `:task_supervisor` - a `Task.Supervisor` name. Without it the task is
      linked to the caller; with it the task is started under the supervisor.
      An unreachable supervisor answers `{:error, {:task_supervisor, reason}}`
      instead of exiting the caller.
  """
  @spec run((-> term()), timeout(), keyword()) :: term()
  def run(fun, timeout, opts) do
    case run_tagged(fun, timeout, opts) do
      {:ok, result} -> result
      {:timeout, timeout} -> {:error, {:timeout, timeout}}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec run_tagged((-> term()), timeout(), keyword()) ::
          {:ok, term()} | {:timeout, non_neg_integer()} | {:error, term()}
  def run_tagged(fun, :infinity, _opts), do: {:ok, fun.()}

  def run_tagged(fun, timeout, opts) when is_integer(timeout) and timeout >= 0 do
    case start_task(fun, opts) do
      {:ok, task} ->
        case Task.yield(task, timeout) do
          {:ok, result} -> {:ok, result}
          {:exit, reason} -> {:error, {:exited, reason}}
          nil -> shutdown_task(Task.shutdown(task, :brutal_kill), timeout)
        end

      {:error, _reason} = error ->
        error
    end
  end

  def run_tagged(_fun, timeout, _opts) do
    raise ArgumentError,
          "timeout must be :infinity or a non-negative integer, got: #{inspect(timeout)}"
  end

  defp start_task(fun, opts) do
    case Keyword.get(opts, :task_supervisor) do
      nil ->
        {:ok, Task.async(fun)}

      supervisor ->
        try do
          {:ok, Task.Supervisor.async_nolink(supervisor, fun)}
        catch
          :exit, reason -> {:error, {:task_supervisor, reason}}
        end
    end
  end

  defp shutdown_task({:ok, result}, _timeout), do: {:ok, result}
  defp shutdown_task({:exit, reason}, _timeout), do: {:error, {:exited, reason}}
  defp shutdown_task(nil, timeout), do: {:timeout, timeout}

  @doc false
  @spec validate!(term()) :: timeout()
  def validate!(:infinity), do: :infinity
  def validate!(timeout) when is_integer(timeout) and timeout >= 0, do: timeout

  def validate!(other) do
    raise ArgumentError,
          "timeout must be :infinity or a non-negative integer, got: #{inspect(other)}"
  end
end
