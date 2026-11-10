defmodule ToolCall.AuditTest.Recorder do
  @moduledoc false
  @behaviour ToolCall.Audit

  @impl true
  def record(entry) do
    case Process.whereis(:tool_call_audit_test) do
      nil -> :ok
      pid -> send(pid, {:audit, entry})
    end
  end
end

defmodule ToolCall.AuditTest.Raising do
  @moduledoc false
  @behaviour ToolCall.Audit

  @impl true
  def record(_entry), do: raise("audit boom")
end

defmodule ToolCall.AuditTest.ApprovalPolicy do
  @moduledoc false
  @behaviour ToolCall.Approval

  @impl true
  def check(_tool, _args, context) do
    cond do
      context[:deny] -> {:deny, "denied"}
      context[:ask] -> {:required, "confirm"}
      true -> :approve
    end
  end
end

defmodule ToolCall.AuditTest do
  use ExUnit.Case, async: true

  import ToolCall.TestModule

  alias ToolCall.Audit.Entry

  @moduletag capture_log: true

  setup do
    Process.register(self(), :tool_call_audit_test)
    :ok
  end

  defp basic_module do
    compile!("""
    defmodule FIXTURE do
      use ToolCall, audit: ToolCall.AuditTest.Recorder

      @doc "Ok."
      @spec ok(x :: integer()) :: integer()
      def ok(x), do: x

      @doc "Boom."
      @spec boom(x :: integer()) :: integer()
      def boom(_x), do: raise("boom")

      @doc "Own timeout."
      @spec own_timeout(ms :: integer()) :: {:error, {:timeout, integer()}}
      def own_timeout(ms), do: {:error, {:timeout, ms}}

      @doc "Own denial."
      @spec own_denial(x :: integer()) :: {:error, {:approval_denied, String.t()}}
      def own_denial(_x), do: {:error, {:approval_denied, "tool says no"}}
    end
    """)
  end

  defp plain_module do
    compile!("""
    defmodule FIXTURE do
      use ToolCall

      @doc "Ok."
      @spec ok(x :: integer()) :: integer()
      def ok(x), do: x
    end
    """)
  end

  defp timeout_module do
    compile!("""
    defmodule FIXTURE do
      use ToolCall, audit: ToolCall.AuditTest.Recorder, timeout: 10

      @doc "Sleep."
      @spec sleep(ms :: integer()) :: :ok
      def sleep(ms) do
        Process.sleep(ms)
        :ok
      end
    end
    """)
  end

  defp approval_module do
    compile!("""
    defmodule FIXTURE do
      use ToolCall,
        audit: ToolCall.AuditTest.Recorder,
        approval: ToolCall.AuditTest.ApprovalPolicy

      @doc "Danger."
      @spec danger(x :: integer()) :: integer()
      def danger(x), do: x
    end
    """)
  end

  test "records an ok dispatch" do
    module = basic_module()

    assert {:ok, 1} = ToolCall.run(module, :ok, %{"x" => 1}, context: %{user_id: 1})

    assert_receive {:audit, %Entry{} = entry}
    assert entry.module == module
    assert entry.tool == "ok"
    assert entry.args == %{"x" => 1}
    assert entry.context == %{user_id: 1}
    assert entry.outcome == :ok
    assert is_integer(entry.duration_us)
    assert entry.error == nil
  end

  test "records invalid arguments before invoking" do
    module = basic_module()

    assert {:error, {:missing_argument, "x"}} = ToolCall.run(module, :ok, %{})

    assert_receive {:audit, %Entry{outcome: :invalid_arguments, error: {:missing_argument, "x"}}}
  end

  test "records non-map arguments" do
    module = basic_module()

    assert {:error, {:invalid_arguments, "nope"}} = ToolCall.run(module, :ok, "nope")

    assert_receive {:audit,
                    %Entry{
                      outcome: :invalid_arguments,
                      error: {:invalid_arguments, "nope"},
                      tool: "ok",
                      duration_us: 0
                    }}
  end

  test "records non-map arguments with an explicit audit policy" do
    module = plain_module()

    assert {:error, {:invalid_arguments, "nope"}} =
             ToolCall.run(module, :ok, "nope", audit: ToolCall.AuditTest.Recorder)

    assert_receive {:audit,
                    %Entry{outcome: :invalid_arguments, error: {:invalid_arguments, "nope"}}}
  end

  test "records an unknown tool" do
    module = basic_module()

    assert {:error, {:unknown_tool, "nope", _}} = ToolCall.run(module, :nope, %{"x" => 1})

    assert_receive {:audit, %Entry{outcome: :unknown_tool, tool: "nope", args: %{"x" => 1}}}
  end

  test "records a raised tool" do
    module = basic_module()

    assert {:error, {:raised, "boom"}} = ToolCall.run(module, :boom, %{"x" => 1})

    assert_receive {:audit, %Entry{outcome: :raised, error: "boom"}}
  end

  test "records a timeout" do
    module = timeout_module()

    assert {:error, {:timeout, 10}} = ToolCall.run(module, :sleep, %{"ms" => 100})

    assert_receive {:audit, %Entry{outcome: :timeout, timeout: 10}}
  end

  test "a tool's own timeout-shaped error is an error, not a dispatch timeout" do
    module = basic_module()

    assert {:error, {:timeout, 10}} = ToolCall.run(module, :own_timeout, %{"ms" => 10})

    assert_receive {:audit, %Entry{outcome: :error, error: {:timeout, 10}, timeout: nil}}
  end

  test "a tool's own denial-shaped error is an error, not an approval denial" do
    module = basic_module()

    assert {:error, {:approval_denied, "tool says no"}} =
             ToolCall.run(module, :own_denial, %{"x" => 1})

    assert_receive {:audit, %Entry{outcome: :error, error: {:approval_denied, "tool says no"}}}
  end

  test "records pending and denied approvals" do
    module = approval_module()

    assert {:pending, request} =
             ToolCall.run(module, :danger, %{"x" => 1}, context: %{ask: true})

    assert_receive {:audit, %Entry{outcome: :pending, approval_request_id: id}}
    assert id == request.id

    assert {:error, {:approval_denied, "denied"}} =
             ToolCall.run(module, :danger, %{"x" => 1}, context: %{deny: true})

    assert_receive {:audit, %Entry{outcome: :denied, error: "denied"}}
  end

  test "an explicit audit policy overrides the module policy" do
    module = plain_module()

    assert {:ok, 1} = ToolCall.run(module, :ok, %{"x" => 1}, audit: ToolCall.AuditTest.Recorder)
    assert_receive {:audit, %Entry{outcome: :ok, module: ^module}}
  end

  test "audit: nil disables the module policy" do
    module = basic_module()

    assert {:ok, 1} = ToolCall.run(module, :ok, %{"x" => 1}, audit: nil)
    refute_receive {:audit, _entry}, 50
  end

  test "records an exception from an approval policy and re-raises" do
    module =
      compile!("""
      defmodule RaisingApproval do
        @behaviour ToolCall.Approval

        @impl true
        def check(_tool, _args, _context), do: raise("approval boom")
      end

      defmodule FIXTURE do
        use ToolCall, audit: ToolCall.AuditTest.Recorder, approval: RaisingApproval

        @doc "Ok."
        @spec ok(x :: integer()) :: integer()
        def ok(x), do: x
      end
      """)

    assert_raise RuntimeError, "approval boom", fn ->
      ToolCall.run(module, :ok, %{"x" => 1})
    end

    assert_receive {:audit, %Entry{outcome: :error, error: {:exception, "approval boom"}}}
  end

  test "records a timeout policy failure as an error" do
    module =
      compile!("""
      defmodule RaisingTimeout do
        @behaviour ToolCall.Timeout

        @impl true
        def timeout(_tool, _args, _context), do: raise("timeout boom")
      end

      defmodule FIXTURE do
        use ToolCall, audit: ToolCall.AuditTest.Recorder, timeout: RaisingTimeout

        @doc "Ok."
        @spec ok(x :: integer()) :: integer()
        def ok(x), do: x
      end
      """)

    assert {:error, {:invalid_timeout, "timeout boom"}} =
             ToolCall.run(module, :ok, %{"x" => 1})

    assert_receive {:audit, %Entry{outcome: :error, error: {:invalid_timeout, "timeout boom"}}}
  end

  test "records an invalid timeout override before re-raising" do
    module = basic_module()

    assert_raise ArgumentError, ~r/timeout/, fn ->
      ToolCall.run(module, :ok, %{"x" => 1}, timeout: -1)
    end

    assert_receive {:audit, %Entry{outcome: :error, error: {:exception, message}}}
    assert message =~ "timeout"
  end

  test "records invalid runtime IR and re-raises" do
    module = basic_module()

    bad = %ToolCall.IR.Tool{
      name: "go",
      description: "Go.",
      params: [
        %ToolCall.IR.Param{name: "x", type: %ToolCall.IR.Type{kind: :bogus}}
      ]
    }

    assert_raise ArgumentError, ~r/unknown kind/, fn ->
      ToolCall.Runner.run(module, [bad], :go, %{"x" => 1})
    end

    assert_receive {:audit, %Entry{outcome: :error, error: {:exception, message}}}
    assert message =~ "unknown kind"
  end

  test "a module-level audit policy without record/1 raises" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall, audit: :nope

        @doc "Ok."
        @spec ok(x :: integer()) :: integer()
        def ok(x), do: x
      end
      """)

    assert_raise ArgumentError, ~r/does not export record\/1/, fn ->
      ToolCall.run(module, :ok, %{"x" => 1})
    end
  end

  test "a boolean audit policy is rejected" do
    module = plain_module()

    assert_raise ArgumentError, ~r/audit/, fn ->
      ToolCall.run(module, :ok, %{"x" => 1}, audit: true)
    end
  end

  test "a raising audit hook does not change the result" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall, audit: ToolCall.AuditTest.Raising

        @doc "Ok."
        @spec ok(x :: integer()) :: integer()
        def ok(x), do: x
      end
      """)

    assert {:ok, 1} = ToolCall.run(module, :ok, %{"x" => 1})
  end

  test "an invalid audit policy raises" do
    module = plain_module()

    assert_raise ArgumentError, ~r/does not export record\/1/, fn ->
      ToolCall.run(module, :ok, %{"x" => 1}, audit: :nope)
    end
  end

  test "resolve and execute record the dispatch" do
    module = basic_module()
    tool = Enum.find(ToolCall.tools(module), &(&1.name == "ok"))

    assert {:ok, call} = ToolCall.Runner.resolve(module, tool, %{"x" => 1})
    assert {:ok, 1} = ToolCall.Runner.execute(call)

    assert_receive {:audit, %Entry{outcome: :ok, tool: "ok"}}
  end

  test "execute uses the context stored by resolve" do
    module = basic_module()
    tool = Enum.find(ToolCall.tools(module), &(&1.name == "ok"))

    assert {:ok, call} =
             ToolCall.Runner.resolve(module, tool, %{"x" => 1}, context: %{user_id: 7})

    assert {:ok, 1} = ToolCall.Runner.execute(call)
    assert_receive {:audit, %Entry{outcome: :ok, context: %{user_id: 7}}}
  end

  test "a call-specific audit policy records an approval exception" do
    module =
      compile!("""
      defmodule CallRaisingApproval do
        @behaviour ToolCall.Approval

        @impl true
        def check(_tool, _args, _context), do: raise("approval boom")
      end

      defmodule FIXTURE do
        use ToolCall

        @doc "Ok."
        @spec ok(x :: integer()) :: integer()
        def ok(x), do: x
      end
      """)

    tool = Enum.find(ToolCall.tools(module), &(&1.name == "ok"))

    assert {:ok, call} =
             ToolCall.Runner.resolve(module, tool, %{"x" => 1},
               audit: ToolCall.AuditTest.Recorder,
               approval: CallRaisingApproval
             )

    assert_raise RuntimeError, "approval boom", fn -> ToolCall.Runner.execute(call) end

    assert_receive {:audit, %Entry{outcome: :error, error: {:exception, "approval boom"}}}
  end
end
