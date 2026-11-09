defmodule ToolCall.StructTypesTest do
  use ExUnit.Case, async: true

  alias ToolCall.IR.{Param, Tool, Type}
  import ToolCall.TestModule

  alias ToolCall.TestFixtures.{Address, FriendA, TreeNode}

  defp tool(source) do
    module = compile!(source)
    Enum.find(ToolCall.tools(module), &(&1.name == "go"))
  end

  @ship """
  defmodule FIXTURE do
    use ToolCall
    @doc "Ship."
    @spec go(to :: ToolCall.TestFixtures.Address.t()) :: map()
    def go(to), do: to
  end
  """

  test "a struct type becomes a closed object with enforce_keys as required" do
    %Tool{params: [%Param{type: type}]} = tool(@ship)

    assert %Type{kind: :object, struct: Address, additional: nil} = type
    assert Enum.map(type.fields, & &1.name) == ["city", "country", "street"]
    assert Enum.map(Enum.filter(type.fields, & &1.required), & &1.name) == ["city"]
    assert %Type{kind: :string} = Enum.find(type.fields, &(&1.name == "country")).type
  end

  test "a struct literal is treated like Mod.t()" do
    %Tool{params: [%Param{type: type}]} =
      tool("""
      defmodule FIXTURE do
        use ToolCall
        @doc "Go."
        @spec go(to :: %ToolCall.TestFixtures.Address{}) :: map()
        def go(to), do: to
      end
      """)

    assert %Type{kind: :object, struct: Address} = type
  end

  test "a field missing from @type t still appears" do
    %Tool{params: [%Param{type: type}]} =
      tool("""
      defmodule FIXTURE do
        use ToolCall
        @doc "Go."
        @spec go(p :: ToolCall.TestFixtures.Partial.t()) :: map()
        def go(p), do: p
      end
      """)

    assert Enum.map(type.fields, & &1.name) == ["a", "b", "c"]
    assert %Type{kind: :any} = Enum.find(type.fields, &(&1.name == "b")).type
  end

  test "an opaque struct type stays untyped with a warning" do
    {module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall
        @doc "Go."
        @spec go(p :: ToolCall.TestFixtures.OpaqueBox.t()) :: map()
        def go(p), do: p
      end
      """)

    tool = module |> ToolCall.tools() |> Enum.find(&(&1.name == "go"))
    assert %Type{kind: :any} = hd(tool.params).type
    assert warnings =~ "no JSON type"
  end

  test "a non-struct remote type stays untyped" do
    {module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall
        @doc "Go."
        @spec go(p :: ToolCall.TestFixtures.NotAStruct.t()) :: map()
        def go(p), do: p
      end
      """)

    tool = module |> ToolCall.tools() |> Enum.find(&(&1.name == "go"))
    assert %Type{kind: :any} = hd(tool.params).type
    assert warnings =~ "no JSON type"
  end

  test "a recursive struct becomes one definition plus a ref" do
    %Tool{defs: defs, params: [%Param{type: root}]} =
      tool("""
      defmodule FIXTURE do
        use ToolCall
        @doc "Go."
        @spec go(n :: ToolCall.TestFixtures.TreeNode.t()) :: map()
        def go(n), do: n
      end
      """)

    assert %Type{kind: :ref, ref: "ToolCall_TestFixtures_TreeNode"} = root
    assert %Type{kind: :object, struct: TreeNode} = defs["ToolCall_TestFixtures_TreeNode"]
  end

  test "providers still win over struct extraction" do
    %Tool{params: [%Param{type: type}]} =
      tool("""
      defmodule FIXTURE do
        use ToolCall
        @doc "Go."
        @spec go(d :: Date.t()) :: map()
        def go(d), do: d
      end
      """)

    assert %Type{kind: :string, format: "date"} = type
  end

  test "a scalar-wrapper struct is extracted, which is a 0.2 compatibility break" do
    %Tool{params: [%Param{type: type}]} =
      tool("""
      defmodule FIXTURE do
        use ToolCall
        @doc "Go."
        @spec go(r :: Range.t()) :: map()
        def go(r), do: r
      end
      """)

    assert %Type{kind: :object, struct: Range, additional: nil} = type
    assert Enum.map(type.fields, & &1.name) == ["first", "last", "step"]
  end

  test "a @typep field inside a struct degrades to untyped" do
    %Tool{params: [%Param{type: type}]} =
      tool("""
      defmodule FIXTURE do
        use ToolCall
        @doc "Go."
        @spec go(p :: ToolCall.TestFixtures.PrivateField.t()) :: map()
        def go(p), do: p
      end
      """)

    assert %Type{kind: :any} = Enum.find(type.fields, &(&1.name == "hidden")).type
  end

  test "a struct inside a recursive local definition is resolved" do
    %Tool{defs: defs, params: [%Param{type: %Type{kind: :ref, ref: "payload"}}]} =
      tool("""
      defmodule FIXTURE do
        use ToolCall
        @type payload :: %{to: ToolCall.TestFixtures.Address.t(), next: payload() | nil}
        @doc "Go."
        @spec go(p :: payload()) :: map()
        def go(p), do: p
      end
      """)

    fields = defs["payload"].fields

    assert %Type{kind: :object, struct: Address} =
             fields |> Enum.find(&(&1.name == "to")) |> Map.fetch!(:type)

    assert %Type{kind: :ref, ref: "payload"} =
             fields |> Enum.find(&(&1.name == "next")) |> Map.fetch!(:type)
  end

  test "mutual struct recursion produces one definition per module" do
    %Tool{defs: defs, params: [%Param{type: root}]} =
      tool("""
      defmodule FIXTURE do
        use ToolCall
        @doc "Go."
        @spec go(a :: ToolCall.TestFixtures.FriendA.t()) :: map()
        def go(a), do: a
      end
      """)

    assert %Type{kind: :ref, ref: "ToolCall_TestFixtures_FriendA"} = root
    assert %Type{kind: :object, struct: FriendA} = defs["ToolCall_TestFixtures_FriendA"]

    assert %Type{kind: :ref, ref: "ToolCall_TestFixtures_FriendB"} =
             defs["ToolCall_TestFixtures_FriendA"].fields
             |> Enum.find(&(&1.name == "b"))
             |> Map.fetch!(:type)
  end

  test "a resolved struct parameter no longer warns about a missing JSON type" do
    {_module, warnings} = compile_with_warnings!(@ship)
    refute warnings =~ "no JSON type"
  end

  test "an untyped field inside a definition warns once, not once per occurrence" do
    {_module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall
        @type tree :: %{value: pid(), children: [tree()]}
        @doc "Go."
        @spec go(x :: tree()) :: map()
        def go(x), do: x
      end
      """)

    assert length(String.split(warnings, "no JSON representation")) == 2
  end

  test "emitted schema closes the struct object" do
    module = compile!(@ship)
    [tool] = ToolCall.emit(module, :anthropic)
    to = tool["input_schema"]["properties"]["to"]

    assert to["additionalProperties"] == false
    assert Enum.sort(to["required"]) == ["city"]
  end
end
