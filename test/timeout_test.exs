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

  test "resolve/4 applies the module timeout constant" do
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

    [tool] = ToolCall.tools(module)

    assert {:ok, %Call{timeout: 10} = call} =
             ToolCall.Runner.resolve(module, tool, %{"ms" => 100})

    assert {:error, {:timeout, 10}} = ToolCall.Runner.execute(call)
  end

  test "resolve/4 applies the module timeout policy" do
    module =
      compile!("""
      defmodule ResolveTimeoutPolicy do
        @behaviour ToolCall.Timeout

        @impl true
        def timeout(%ToolCall.IR.Tool{name: "slow"}, _args, _context), do: 10
        def timeout(_tool, _args, _context), do: 1_000
      end

      defmodule FIXTURE do
        use ToolCall, timeout: ResolveTimeoutPolicy

        @doc "Slow."
        @spec slow(ms :: integer()) :: :ok
        def slow(ms) do
          Process.sleep(ms)
          :ok
        end
      end
      """)

    [tool] = ToolCall.tools(module)

    assert {:ok, %Call{timeout: 10} = call} =
             ToolCall.Runner.resolve(module, tool, %{"ms" => 100})

    assert {:error, {:timeout, 10}} = ToolCall.Runner.execute(call)
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

  test "the module timeout uses the given task supervisor" do
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

    assert {:error, {:task_supervisor, _reason}} =
             ToolCall.run(module, :sleep, %{"ms" => 1},
               task_supervisor: :missing_timeout_supervisor
             )
  end

  test "an invalid timeout raises" do
    module = sleep_module()

    assert_raise ArgumentError, ~r/timeout/, fn ->
      ToolCall.run(module, :sleep, %{"ms" => 1}, timeout: -1)
    end
  end

  test "the timeout policy receives the run context" do
    module =
      compile!("""
      defmodule ContextPolicy do
        @behaviour ToolCall.Timeout

        @impl true
        def timeout(_tool, _args, context) do
          if context[:fast], do: 10, else: 1_000
        end
      end

      defmodule FIXTURE do
        use ToolCall, timeout: ContextPolicy

        @doc "Sleep."
        @spec sleep(ms :: integer()) :: :ok
        def sleep(ms) do
          Process.sleep(ms)
          :ok
        end
      end
      """)

    assert {:ok, :ok} = ToolCall.run(module, :sleep, %{"ms" => 10})

    assert {:error, {:timeout, 10}} =
             ToolCall.run(module, :sleep, %{"ms" => 100}, context: %{fast: true})
  end

  test "the timeout policy runs after validation and sees coerced values" do
    Process.register(self(), :timeout_policy_probe)

    module =
      compile!("""
      defmodule ProbePolicy do
        @behaviour ToolCall.Timeout

        @impl true
        def timeout(_tool, args, _context) do
          if pid = Process.whereis(:timeout_policy_probe), do: send(pid, {:policy_args, args})
          args["ms"] + 1_000
        end
      end

      defmodule FIXTURE do
        use ToolCall, timeout: ProbePolicy

        @doc "Sleep."
        @spec sleep(ms :: integer()) :: :ok
        def sleep(ms) do
          Process.sleep(ms)
          :ok
        end
      end
      """)

    assert {:error, {:invalid_argument, {"ms", {:expected_integer, "oops"}}}} =
             ToolCall.run(module, :sleep, %{"ms" => "oops"})

    refute_receive {:policy_args, _args}, 50

    assert {:ok, :ok} = ToolCall.run(module, :sleep, %{"ms" => 1})
    assert_receive {:policy_args, %{"ms" => 1}}
  end

  test "resolve/4 validates a hand-built tool" do
    bad = %ToolCall.IR.Tool{
      name: "go",
      description: "Go.",
      params: [
        %ToolCall.IR.Param{name: "x", type: %ToolCall.IR.Type{kind: :bogus}}
      ]
    }

    assert_raise ArgumentError, ~r/unknown kind/, fn ->
      ToolCall.Runner.resolve(__MODULE__, bad, %{"x" => 1})
    end
  end
end
