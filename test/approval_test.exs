defmodule ToolCall.ApprovalTest.DenyAll do
  @moduledoc false
  @behaviour ToolCall.Approval

  @impl true
  def check(_tool, _args, _context), do: {:deny, "no"}
end

defmodule ToolCall.ApprovalTest.Weird do
  @moduledoc false
  @behaviour ToolCall.Approval

  @impl true
  def check(_tool, _args, _context), do: :maybe
end

defmodule ToolCall.ApprovalTest do
  use ExUnit.Case, async: true

  import ToolCall.TestModule

  alias ToolCall.Approval.Request

  defp module_with_policy do
    compile!("""
    defmodule ApprovalPolicy do
      @behaviour ToolCall.Approval

      @impl true
      def check(%ToolCall.IR.Tool{name: "danger"}, _args, context) do
        cond do
          context[:deny] -> {:deny, "denied"}
          context[:ask] -> {:required, "confirm"}
          true -> :approve
        end
      end

      def check(_tool, _args, _context), do: :approve
    end

    defmodule FIXTURE do
      use ToolCall, approval: ApprovalPolicy

      @doc "Ok."
      @spec ok(x :: integer()) :: integer()
      def ok(x), do: x

      @doc "Danger."
      @spec danger(x :: integer()) :: integer()
      def danger(x), do: x
    end
    """)
  end

  test "approve runs the tool" do
    module = module_with_policy()
    assert {:ok, 1} = ToolCall.run(module, :ok, %{"x" => 1})
  end

  test "required returns a pending request without invoking" do
    module = module_with_policy()

    assert {:pending, %Request{} = request} =
             ToolCall.run(module, :danger, %{"x" => 1}, context: %{ask: true})

    assert request.module == module
    assert request.tool == "danger"
    assert request.args == %{"x" => 1}
    assert request.reason == "confirm"
    assert request.context == %{ask: true}
    assert is_binary(request.id) and request.id != ""
    assert %DateTime{} = request.inserted_at
  end

  test "deny returns an error without invoking" do
    module = module_with_policy()

    assert {:error, {:approval_denied, "denied"}} =
             ToolCall.run(module, :danger, %{"x" => 1}, context: %{deny: true})
  end

  test "approval: :granted bypasses the policy" do
    module = module_with_policy()
    assert {:ok, 1} = ToolCall.run(module, :danger, %{"x" => 1}, approval: :granted)
  end

  test "approval: :denied refuses without invoking" do
    module = module_with_policy()

    assert {:error, {:approval_denied, :denied}} =
             ToolCall.run(module, :danger, %{"x" => 1}, approval: :denied)
  end

  test "an explicit policy overrides the module policy" do
    module = module_with_policy()

    assert {:error, {:approval_denied, "no"}} =
             ToolCall.run(module, :ok, %{"x" => 1}, approval: ToolCall.ApprovalTest.DenyAll)
  end

  test "an invalid approval result is reported" do
    module = module_with_policy()

    assert {:error, {:invalid_approval, :maybe}} =
             ToolCall.run(module, :ok, %{"x" => 1}, approval: ToolCall.ApprovalTest.Weird)
  end

  test "argument errors are returned before approval" do
    module = module_with_policy()

    assert {:error, {:missing_argument, "x"}} =
             ToolCall.run(module, :danger, %{}, context: %{ask: true})
  end

  test "a pending approval is not timed out" do
    module = module_with_policy()

    assert {:pending, %Request{}} =
             ToolCall.run(module, :danger, %{"x" => 1},
               context: %{ask: true},
               timeout: 1
             )
  end

  test "resolve and execute keep the approval policy on the call" do
    module = module_with_policy()
    [tool] = ToolCall.tools(module) |> Enum.filter(&(&1.name == "danger"))

    assert {:ok, call} = ToolCall.Runner.resolve(module, tool, %{"x" => 1})
    assert {:ok, 1} = ToolCall.Runner.execute(call, approval: :granted)

    assert {:error, {:approval_denied, "denied"}} =
             ToolCall.Runner.execute(call, context: %{deny: true})
  end

  test "an invalid approval policy raises" do
    module = module_with_policy()

    assert_raise ArgumentError, ~r/does not export check\/3/, fn ->
      ToolCall.run(module, :ok, %{"x" => 1}, approval: :grant)
    end
  end
end
