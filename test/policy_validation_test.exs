defmodule ToolCall.PolicyValidationTest do
  use ExUnit.Case, async: true

  import ToolCall.TestModule

  test "accepts valid module-level policies" do
    module =
      compile!("""
      defmodule ValidTimeout do
        @behaviour ToolCall.Timeout
        @impl true
        def timeout(_tool, _args, _context), do: 1_000
      end

      defmodule ValidApproval do
        @behaviour ToolCall.Approval
        @impl true
        def check(_tool, _args, _context), do: :approve
      end

      defmodule ValidAudit do
        @behaviour ToolCall.Audit
        @impl true
        def record(_entry), do: :ok
      end

      defmodule FIXTURE do
        use ToolCall,
          timeout: ValidTimeout,
          approval: ValidApproval,
          audit: ValidAudit

        @doc "Ok."
        @spec ok(x :: integer()) :: integer()
        def ok(x), do: x
      end
      """)

    assert :ok = ToolCall.validate_policies!(module)
  end

  test "accepts module-level approval modes and a constant timeout" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall, timeout: 1_000, approval: :denied

        @doc "Ok."
        @spec ok(x :: integer()) :: integer()
        def ok(x), do: x
      end
      """)

    assert :ok = ToolCall.validate_policies!(module)
  end

  test "rejects an invalid module-level approval policy" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall, approval: :grant

        @doc "Ok."
        @spec ok(x :: integer()) :: integer()
        def ok(x), do: x
      end
      """)

    assert_raise ArgumentError, ~r/does not export check\/3/, fn ->
      ToolCall.validate_policies!(module)
    end
  end

  test "rejects an invalid module-level audit policy" do
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
      ToolCall.validate_policies!(module)
    end
  end

  test "rejects an invalid module-level timeout policy" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall, timeout: :bad

        @doc "Ok."
        @spec ok(x :: integer()) :: integer()
        def ok(x), do: x
      end
      """)

    assert_raise ArgumentError, ~r/does not export timeout\/3/, fn ->
      ToolCall.validate_policies!(module)
    end
  end

  test "rejects a module that does not use ToolCall" do
    assert_raise ArgumentError, ~r/does not use ToolCall/, fn ->
      ToolCall.validate_policies!(String)
    end
  end

  test "the startup child validates and is ignored" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall, approval: :granted

        @doc "Ok."
        @spec ok(x :: integer()) :: integer()
        def ok(x), do: x
      end
      """)

    assert :ignore = ToolCall.PolicyValidation.start_link([module])
    assert :ignore = ToolCall.PolicyValidation.start_link(module)

    assert {:ok, supervisor} =
             Supervisor.start_link([{ToolCall.PolicyValidation, [module]}],
               strategy: :one_for_one
             )

    assert Supervisor.which_children(supervisor) == []
    assert :ok = Supervisor.stop(supervisor)
  end

  test "the startup child fails for an invalid policy" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall, approval: :grant

        @doc "Ok."
        @spec ok(x :: integer()) :: integer()
        def ok(x), do: x
      end
      """)

    assert_raise ArgumentError, ~r/does not export check\/3/, fn ->
      ToolCall.PolicyValidation.start_link([module])
    end
  end

  test "child_spec is a temporary one-shot worker" do
    assert %{
             id: ToolCall.PolicyValidation,
             start: {ToolCall.PolicyValidation, :start_link, [[]]},
             restart: :temporary,
             type: :worker
           } = ToolCall.PolicyValidation.child_spec([])
  end
end
