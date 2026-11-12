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

    assert {:ok, %Call{timeout: :infinity, timeout_policy: ResolveTimeoutPolicy} = call} =
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

  test "a private timed supervisor does not send an exit message to a trapping caller" do
    previous = Process.flag(:trap_exit, true)

    try do
      assert :ok = ToolCall.Timeout.run(fn -> :ok end, 1_000, [])
      refute_receive {:EXIT, _pid, _reason}, 50
    after
      Process.flag(:trap_exit, previous)
    end
  end

  test "a private timed supervisor stops its task when the caller dies" do
    parent = self()

    caller =
      spawn(fn ->
        ToolCall.Timeout.run(
          fn ->
            send(parent, {:task, self()})
            Process.sleep(:infinity)
          end,
          60_000,
          []
        )
      end)

    task =
      receive do
        {:task, task} -> task
      after
        1_000 -> flunk("timed task did not start")
      end

    ref = Process.monitor(task)
    Process.exit(caller, :kill)

    try do
      assert_receive {:DOWN, ^ref, :process, ^task, _reason}, 1_000
    after
      if Process.alive?(task), do: Process.exit(task, :kill)
    end
  end

  test "a raising timed task returns an exited error" do
    assert {:error, {:exited, _reason}} =
             ToolCall.Timeout.run(fn -> raise "boom" end, 1_000, [])
  end

  test "execute/2 rejects options that only resolve/4 supports" do
    module = sleep_module()
    [tool] = ToolCall.tools(module)
    {:ok, call} = ToolCall.Runner.resolve(module, tool, %{"ms" => 1})

    assert_raise ArgumentError, ~r/unknown options/, fn ->
      ToolCall.Runner.execute(call, timeout_policy: 10)
    end

    assert_raise ArgumentError, ~r/unknown options/, fn ->
      ToolCall.Runner.execute(call, validate_result: true)
    end
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

  test "Options rejects a negative timeout_policy" do
    assert_raise ArgumentError, ~r/timeout_policy/, fn ->
      ToolCall.Options.validate!([timeout_policy: -1], [:timeout_policy])
    end
  end

  test "an invalid timeout raises" do
    module = sleep_module()

    assert_raise ArgumentError, ~r/timeout/, fn ->
      ToolCall.run(module, :sleep, %{"ms" => 1}, timeout: -1)
    end
  end

  test "Runner.execute rejects unknown options" do
    module = sleep_module()
    [tool] = ToolCall.tools(module)
    {:ok, call} = ToolCall.Runner.resolve(module, tool, %{"ms" => 1})

    assert_raise ArgumentError, ~r/unknown options/, fn ->
      ToolCall.Runner.execute(call, audti: [])
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

  test "the timeout policy runs after validation and sees raw arguments" do
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

  test "the timeout policy sees the raw wire argument" do
    Process.register(self(), :timeout_policy_raw_probe)

    module =
      compile!("""
      defmodule RawProbePolicy do
        @behaviour ToolCall.Timeout

        @impl true
        def timeout(_tool, args, _context) do
          if pid = Process.whereis(:timeout_policy_raw_probe), do: send(pid, {:policy_args, args})
          1_000
        end
      end

      defmodule FIXTURE do
        use ToolCall, timeout: RawProbePolicy

        @tool_param %{fun: :find, name: "id", wire: :string_integer}
        @doc "Find."
        @spec find(id :: integer()) :: integer()
        def find(id), do: id
      end
      """)

    assert {:ok, 123} = ToolCall.run(module, :find, %{"id" => "123"})
    assert_receive {:policy_args, %{"id" => "123"}}
  end

  test "a pending or denied call does not evaluate the timeout policy" do
    Process.register(self(), :timeout_pending_probe)

    module =
      compile!("""
      defmodule PendingApproval do
        @behaviour ToolCall.Approval

        @impl true
        def check(_tool, _args, context) do
          if context[:ask], do: {:required, "ask"}, else: {:deny, "no"}
        end
      end

      defmodule PendingTimeout do
        @behaviour ToolCall.Timeout

        @impl true
        def timeout(_tool, _args, _context) do
          if pid = Process.whereis(:timeout_pending_probe), do: send(pid, :policy_called)
          10
        end
      end

      defmodule FIXTURE do
        use ToolCall, timeout: PendingTimeout, approval: PendingApproval

        @doc "Ok."
        @spec ok(x :: integer()) :: integer()
        def ok(x), do: x
      end
      """)

    assert {:pending, _request} = ToolCall.run(module, :ok, %{"x" => 1}, context: %{ask: true})
    refute_receive :policy_called, 50

    assert {:error, {:approval_denied, "no"}} =
             ToolCall.run(module, :ok, %{"x" => 1}, context: %{})

    refute_receive :policy_called, 50
  end

  test "an invalid execute timeout is rejected before approval" do
    Process.register(self(), :timeout_order_probe)

    module =
      compile!("""
      defmodule OrderApproval do
        @behaviour ToolCall.Approval

        @impl true
        def check(_tool, _args, _context) do
          if pid = Process.whereis(:timeout_order_probe), do: send(pid, :approval_called)
          :approve
        end
      end

      defmodule FIXTURE do
        use ToolCall, approval: OrderApproval

        @doc "Ok."
        @spec ok(x :: integer()) :: integer()
        def ok(x), do: x
      end
      """)

    [tool] = ToolCall.tools(module)
    {:ok, call} = ToolCall.Runner.resolve(module, tool, %{"x" => 1})

    assert_raise ArgumentError, ~r/timeout/, fn ->
      ToolCall.Runner.execute(call, timeout: -1)
    end

    refute_receive :approval_called, 50
  end

  test "an infinite timeout still uses a task supervisor" do
    module = sleep_module()
    {:ok, supervisor} = Task.Supervisor.start_link()

    assert {:ok, :ok} =
             ToolCall.run(module, :sleep, %{"ms" => 1}, task_supervisor: supervisor)

    assert {:error, {:task_supervisor, _reason}} =
             ToolCall.run(module, :sleep, %{"ms" => 1},
               task_supervisor: :missing_infinite_supervisor
             )
  end

  test "a raising timeout policy returns an error" do
    module =
      compile!("""
      defmodule RaisingTimeoutPolicy do
        @behaviour ToolCall.Timeout

        @impl true
        def timeout(_tool, _args, _context), do: raise("timeout boom")
      end

      defmodule FIXTURE do
        use ToolCall, timeout: RaisingTimeoutPolicy

        @doc "Ok."
        @spec ok(x :: integer()) :: integer()
        def ok(x), do: x
      end
      """)

    assert {:error, {:invalid_timeout, "timeout boom"}} =
             ToolCall.run(module, :ok, %{"x" => 1})
  end

  test "a timeout policy returning an invalid value returns an error" do
    module =
      compile!("""
      defmodule InvalidTimeoutPolicy do
        @behaviour ToolCall.Timeout

        @impl true
        def timeout(_tool, _args, _context), do: :bad
      end

      defmodule FIXTURE do
        use ToolCall, timeout: InvalidTimeoutPolicy

        @doc "Ok."
        @spec ok(x :: integer()) :: integer()
        def ok(x), do: x
      end
      """)

    assert {:error, {:invalid_timeout, message}} =
             ToolCall.run(module, :ok, %{"x" => 1})

    assert message =~ "timeout must be"
  end

  test "Timeout.run/3 treats an invalid supervisor term as an error" do
    assert {:error, {:task_supervisor, _reason}} =
             ToolCall.Timeout.run(fn -> :ok end, 100, task_supervisor: "bad")

    assert {:error, {:task_supervisor, _reason}} =
             ToolCall.Timeout.run(fn -> :ok end, :infinity, task_supervisor: "bad")
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
