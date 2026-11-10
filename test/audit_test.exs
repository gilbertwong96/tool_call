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
end
