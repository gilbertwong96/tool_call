# reach:disable-for-this-file bare_rescue
# Total boundary: any exception from the wrapped operation is converted to a
# result; no exception is meant to escape this module.
defmodule ToolCall.Timeout do
  @moduledoc """
  Per-invocation timeouts and the timeout policy behaviour.

  `run/3` executes a zero-arity function in a task for a finite timeout and
  answers `{:error, {:timeout, ms}}` when it does not finish in time. With
  `:infinity` it runs in the caller unless a `:task_supervisor` is given. The
  task is killed with `:brutal_kill`; it is **not** a cancellation: the function
  may already have produced its side effect. A tool that owns resources or
  relies on the caller's process (`self/0`, the process dictionary, Ecto sandbox
  ownership) should use a cooperative timeout instead.

  A module implementing `timeout/3` can be passed to
  `use ToolCall, timeout: MyPolicy`; `ToolCall.run/4` with `timeout: ms` wins
  over the policy. `timeout/3` receives the tool IR, the validated raw argument
  map and the caller's context. It runs when the call executes, after approval,
  not during `resolve/4`; its own execution is not covered by the timeout it
  computes.
  """

  alias ToolCall.IR.Tool

  @callback timeout(Tool.t(), map(), term()) :: timeout()

  @doc """
  Runs `fun` with a timeout.

  Options:

    * `:task_supervisor` - a `Task.Supervisor` name. With a finite timeout the
      task is started under the supervisor; with `:infinity` a supervisor still
      starts a task. Without a supervisor, a finite timeout uses a task linked
      to the caller and `:infinity` runs in the caller. An unreachable or
      invalid supervisor answers `{:error, {:task_supervisor, reason}}` instead
      of exiting the caller.
  """
  @spec run((-> term()), timeout(), keyword()) :: term()
  def run(fun, timeout, opts) do
    case run_tagged(fun, timeout, opts) do
      {:ok, result} -> result
      {:timeout, timeout} -> {:error, {:timeout, timeout}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Internal timer used by `ToolCall.Runner.execute/2`.

  Like `run/3`, but distinguishes a dispatcher timeout from a function result.
  """
  @spec run_tagged((-> term()), timeout(), keyword()) ::
          {:ok, term()} | {:timeout, non_neg_integer()} | {:error, term()}
  def run_tagged(fun, :infinity, opts) do
    case Keyword.get(opts, :task_supervisor) do
      nil ->
        {:ok, fun.()}

      _supervisor ->
        with {:ok, task} <- start_task(fun, opts), do: await_task(task)
    end
  end

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

      supervisor when is_atom(supervisor) or is_pid(supervisor) ->
        try do
          {:ok, Task.Supervisor.async_nolink(supervisor, fun)}
        rescue
          exception -> {:error, {:task_supervisor, exception}}
        catch
          :exit, reason -> {:error, {:task_supervisor, reason}}
          kind, value -> {:error, {:task_supervisor, {kind, value}}}
        end

      other ->
        {:error, {:task_supervisor, {:invalid, other}}}
    end
  end

  defp shutdown_task({:ok, result}, _timeout), do: {:ok, result}
  defp shutdown_task({:exit, reason}, _timeout), do: {:error, {:exited, reason}}
  defp shutdown_task(nil, timeout), do: {:timeout, timeout}

  defp await_task(task) do
    case Task.yield(task, :infinity) do
      {:ok, result} -> {:ok, result}
      {:exit, reason} -> {:error, {:exited, reason}}
      nil -> {:error, {:exited, :no_result}}
    end
  end

  @doc """
  Validates a timeout value, raising `ArgumentError` when it is not `:infinity`
  or a non-negative integer.
  """
  @spec validate!(term()) :: timeout()
  def validate!(:infinity), do: :infinity
  def validate!(timeout) when is_integer(timeout) and timeout >= 0, do: timeout

  def validate!(other) do
    raise ArgumentError,
          "timeout must be :infinity or a non-negative integer, got: #{inspect(other)}"
  end
end
