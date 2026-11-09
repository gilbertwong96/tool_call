defmodule ToolCall.StructTypesTest do
  use ExUnit.Case, async: true

  alias ToolCall.IR.{Param, Tool, Type}
  import ToolCall.TestModule

  alias ToolCall.TestFixtures.{
    Address,
    ChainHost,
    FriendA,
    NoType,
    PathNode,
    TreeNode,
    WeirdType
  }

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

  test "an opaque struct type is not exposed" do
    {module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall
        @doc "Go."
        @spec go(p :: ToolCall.TestFixtures.OpaqueBox.t()) :: map()
        def go(p), do: p
      end
      """)

    assert ToolCall.tools(module) == []
    assert warnings =~ "@opaque"
    assert warnings =~ ~s(tool "go" is not exposed: parameter "p")
  end

  test "a non-struct remote type is not exposed" do
    {module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall
        @doc "Go."
        @spec go(p :: ToolCall.TestFixtures.NotAStruct.t()) :: map()
        def go(p), do: p
      end
      """)

    assert ToolCall.tools(module) == []
    assert warnings =~ ~s(tool "go" is not exposed: parameter "p")
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

  test "a struct module's own cyclic local type is hoisted to defs" do
    %Tool{defs: defs, params: [%Param{type: type}]} =
      tool("""
      defmodule FIXTURE do
        use ToolCall
        @doc "Go."
        @spec go(p :: ToolCall.TestFixtures.PathNode.t()) :: map()
        def go(p), do: p
      end
      """)

    assert %Type{kind: :object, struct: PathNode} = type

    assert %Type{kind: :ref, ref: "ToolCall_TestFixtures_PathNode_path"} =
             type.fields |> Enum.find(&(&1.name == "tail")) |> Map.fetch!(:type)

    assert Map.has_key?(defs, "ToolCall_TestFixtures_PathNode_path")
  end

  test "a struct nested in a tuple or a map field is resolved" do
    %Tool{params: [%Param{type: type}]} =
      tool("""
      defmodule FIXTURE do
        use ToolCall
        @doc "Go."
        @spec go(s :: ToolCall.TestFixtures.Shapes.t()) :: map()
        def go(s), do: s
      end
      """)

    assert Enum.map(type.fields, & &1.name) == ["map", "pair"]

    assert %Type{
             kind: :tuple,
             items: [%Type{kind: :object, struct: Address}, %Type{kind: :integer}]
           } =
             type.fields |> Enum.find(&(&1.name == "pair")) |> Map.fetch!(:type)

    assert %Type{
             kind: :object,
             fields: [%{name: "a", type: %Type{kind: :object, struct: Address}}]
           } =
             type.fields |> Enum.find(&(&1.name == "map")) |> Map.fetch!(:type)
  end

  test "a struct with no @type t, or a t that is not a struct, exposes untyped fields" do
    %Tool{params: [%Param{type: no_type}]} =
      tool("""
      defmodule FIXTURE do
        use ToolCall
        @doc "Go."
        @spec go(x :: ToolCall.TestFixtures.NoType.t()) :: map()
        def go(x), do: x
      end
      """)

    assert %Type{kind: :object, struct: NoType, fields: [%{name: "x", type: %Type{kind: :any}}]} =
             no_type

    %Tool{params: [%Param{type: weird}]} =
      tool("""
      defmodule FIXTURE do
        use ToolCall
        @doc "Go."
        @spec go(x :: ToolCall.TestFixtures.WeirdType.t()) :: map()
        def go(x), do: x
      end
      """)

    assert %Type{
             kind: :object,
             struct: WeirdType,
             fields: [%{name: "x", type: %Type{kind: :any}}]
           } =
             weird
  end

  test "a struct reachable only through a struct module's cyclic local type is resolved" do
    %Tool{defs: defs, params: [%Param{type: type}]} =
      tool("""
      defmodule FIXTURE do
        use ToolCall
        @doc "Go."
        @spec go(x :: ToolCall.TestFixtures.ChainHost.t()) :: map()
        def go(x), do: x
      end
      """)

    assert %Type{kind: :object, struct: ChainHost} = type

    assert %Type{kind: :ref, ref: "ToolCall_TestFixtures_ChainHost_chain"} =
             type.fields |> Enum.find(&(&1.name == "node")) |> Map.fetch!(:type)

    assert %Type{kind: :object, struct: Address} =
             defs["ToolCall_TestFixtures_ChainHost_chain"].fields
             |> Enum.find(&(&1.name == "node"))
             |> Map.fetch!(:type)
  end

  test "a struct whose @type t hits the inlining budget warns" do
    {_module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall
        @doc "Go."
        @spec go(x :: ToolCall.TestFixtures.Deep.t()) :: map()
        def go(x), do: x
      end
      """)

    assert warnings =~ "expansion budget"
    assert warnings =~ "ToolCall.TestFixtures.Deep"
  end

  test "a parameterized-only @type t warns instead of silently untyping" do
    {_module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall
        @doc "Go."
        @spec go(x :: ToolCall.TestFixtures.ParamOnly.t()) :: map()
        def go(x), do: x
      end
      """)

    assert warnings =~ "only a parameterized @type t"
  end

  test "a t/0 that is not a struct literal warns" do
    {_module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall
        @doc "Go."
        @spec go(x :: ToolCall.TestFixtures.WeirdType.t()) :: map()
        def go(x), do: x
      end
      """)

    assert warnings =~ "is not a %__MODULE__{} literal"
  end

  test "an exception struct exposes its payload, not __exception__" do
    %Tool{params: [%Param{type: type}]} =
      tool("""
      defmodule FIXTURE do
        use ToolCall
        @doc "Go."
        @spec go(e :: ArgumentError.t()) :: map()
        def go(e), do: e
      end
      """)

    assert %Type{kind: :object, struct: ArgumentError} = type
    assert Enum.map(type.fields, & &1.name) == ["message"]
  end

  test "dispatch builds a usable exception" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall
        @doc "Go."
        @spec go(e :: ArgumentError.t()) :: String.t()
        def go(e), do: Exception.message(e)
      end
      """)

    assert {:ok, "boom"} = ToolCall.run(module, :go, %{"e" => %{"message" => "boom"}})
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

    assert warnings |> String.split("no JSON representation") |> Enum.count_until(3) == 2
  end

  test "emitted schema closes the struct object" do
    module = compile!(@ship)
    [tool] = ToolCall.emit(module, :anthropic)
    to = tool["input_schema"]["properties"]["to"]

    assert to["additionalProperties"] == false
    assert Enum.sort(to["required"]) == ["city"]
  end

  defp run(source, name, args) do
    module = compile!(source)
    ToolCall.run(module, name, args)
  end

  test "dispatch returns the declared struct with defaults applied" do
    assert {:ok, %ToolCall.TestFixtures.Address{city: "Oslo", street: nil, country: "NO"}} =
             run(@ship, :go, %{"to" => %{"city" => "Oslo"}})
  end

  test "dispatch rejects an unknown struct field" do
    assert {:error, {:invalid_argument, {"to", {:unknown_keys, ["zip"]}}}} =
             run(@ship, :go, %{"to" => %{"city" => "Oslo", "zip" => "0150"}})
  end

  test "dispatch reconstructs a recursive struct at every level" do
    source = """
    defmodule FIXTURE do
      use ToolCall
      @doc "Go."
      @spec go(n :: ToolCall.TestFixtures.TreeNode.t()) :: map()
      def go(n), do: n
    end
    """

    expected = %ToolCall.TestFixtures.TreeNode{
      value: 1,
      children: [%ToolCall.TestFixtures.TreeNode{value: 2, children: []}]
    }

    args = %{"n" => %{"value" => 1, "children" => [%{"value" => 2, "children" => []}]}}
    assert {:ok, ^expected} = run(source, :go, args)
  end

  test "a struct problem warns once per module, not once per tool" do
    {_module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "A."
        @spec a(x :: ToolCall.TestFixtures.ParamOnly.t()) :: map()
        def a(x), do: x

        @doc "B."
        @spec b(x :: ToolCall.TestFixtures.ParamOnly.t()) :: map()
        def b(x), do: x

        @doc "C."
        @spec c(x :: ToolCall.TestFixtures.ParamOnly.t()) :: map()
        def c(x), do: x
      end
      """)

    assert warnings |> String.split("only a parameterized @type t") |> Enum.count_until(3) == 2
  end
end
