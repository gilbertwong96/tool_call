defmodule ToolCall.TimeoutTest do
  use ExUnit.Case, async: true

  @moduletag capture_log: true

  import ToolCall.TestModule

  alias ToolCall.Call

  defp sleep_module do
    compile!("""
    defmodule FIXTURE do
      use ToolCall

      @doc "Sleep."
      @spec sleep(ms :: integer()) :: :ok
      def sleep(ms) do
        Process.sleep(ms)
        :ok
      end
    end
    """)
  end

  test "run/4 applies a timeout" do
    module = sleep_module()

    {micros, result} =
      :timer.tc(fn -> ToolCall.run(module, :sleep, %{"ms" => 200}, timeout: 10) end)

    assert result == {:error, {:timeout, 10}}
    assert micros < 150_000
  end

  test "run/4 without a timeout still runs" do
    module = sleep_module()

    assert {:ok, :ok} = ToolCall.run(module, :sleep, %{"ms" => 1})
    assert {:ok, :ok} = ToolCall.run(module, :sleep, %{"ms" => 1}, timeout: :infinity)
  end

  test "run/3 uses the module timeout" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall, timeout: 10

        @doc "Sleep."
        @spec sleep(ms :: integer()) :: :ok
        def sleep(ms) do
          Process.sleep(ms)
          :ok
        end
      end
      """)

    assert {:error, {:timeout, 10}} = ToolCall.run(module, :sleep, %{"ms" => 100})
    assert {:ok, :ok} = ToolCall.run(module, :sleep, %{"ms" => 1})
    assert {:ok, :ok} = ToolCall.run(module, :sleep, %{"ms" => 20}, timeout: :infinity)
  end

  test "a timeout policy applies per tool" do
    module =
      compile!("""
      defmodule TimeoutPolicy do
        @behaviour ToolCall.Timeout

        @impl true
        def timeout(%ToolCall.IR.Tool{name: "slow"}, _args, _context), do: 10
        def timeout(_tool, _args, _context), do: 1_000
      end

      defmodule FIXTURE do
        use ToolCall, timeout: TimeoutPolicy

        @doc "Slow."
        @spec slow(ms :: integer()) :: :ok
        def slow(ms) do
          Process.sleep(ms)
          :ok
        end

        @doc "Fast."
        @spec fast(ms :: integer()) :: :ok
        def fast(ms) do
          Process.sleep(ms)
          :ok
        end
      end
      """)

    assert {:error, {:timeout, 10}} = ToolCall.run(module, :slow, %{"ms" => 100})
    assert {:ok, :ok} = ToolCall.run(module, :fast, %{"ms" => 1})
  end

  test "resolve/4 does not invoke and execute/2 does" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Boom."
        @spec boom() :: :ok
        def boom, do: raise("boom")
      end
      """)

    [tool] = ToolCall.tools(module)

    assert {:ok, %Call{} = call} = ToolCall.Runner.resolve(module, tool, %{})
    assert {:error, {:raised, "boom"}} = ToolCall.Runner.execute(call)
  end

  test "execute/2 accepts a timeout override" do
    module = sleep_module()
    [tool] = ToolCall.tools(module)

    assert {:ok, call} = ToolCall.Runner.resolve(module, tool, %{"ms" => 100})

    assert {:error, {:timeout, 10}} = ToolCall.Runner.execute(call, timeout: 10)
  end

  test "a task supervisor can own the timed invocation" do
    module = sleep_module()
    {:ok, supervisor} = Task.Supervisor.start_link()

    assert {:error, {:timeout, 10}} =
             ToolCall.run(module, :sleep, %{"ms" => 100},
               timeout: 10,
               task_supervisor: supervisor
             )
  end

  test "an invalid timeout raises" do
    module = sleep_module()

    assert_raise ArgumentError, ~r/timeout/, fn ->
      ToolCall.run(module, :sleep, %{"ms" => 1}, timeout: -1)
    end
  end
end
