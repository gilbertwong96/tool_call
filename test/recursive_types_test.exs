defmodule ToolCall.RecursiveTypesTest do
  use ExUnit.Case, async: true

  alias ToolCall.IR.{Param, Tool, Type}
  import ToolCall.TestModule

  defp tool(source, name) do
    module = compile!(source)
    Enum.find(ToolCall.tools(module), &(&1.name == name))
  end

  @tree """
  defmodule FIXTURE do
    use ToolCall

    @type tree :: %{value: integer(), children: [tree()]}

    @doc "Walk."
    @spec walk(root :: tree()) :: map()
    def walk(root), do: root
  end
  """

  @shapes """
  defmodule FIXTURE do
    use ToolCall

    @type shape :: %{
            kind: :leaf | :branch,
            pair: {shape(), integer()},
            peers: %{optional(String.t()) => shape()},
            items: [shape()]
          }

    @doc "Go."
    @spec go(s :: shape()) :: map()
    def go(s), do: s
  end
  """

  test "a recursive parameter is a ref with one definition" do
    %Tool{defs: defs, params: [%Param{name: "root", type: root}]} = tool(@tree, "walk")

    assert %Type{kind: :ref, ref: "tree"} = root
    assert %Type{kind: :object, fields: fields} = defs["tree"]
    children = Enum.find(fields, &(&1.name == "children"))
    assert %Type{kind: :array, items: %Type{kind: :ref, ref: "tree"}} = children.type
  end

  test "mutual recursion produces one definition per type" do
    %Tool{defs: defs, params: [%Param{type: root}]} =
      tool(
        """
        defmodule FIXTURE do
          use ToolCall
          @type a :: %{b: b()}
          @type b :: %{a: a(), n: integer()}
          @doc "A."
          @spec go(x :: a()) :: map()
          def go(x), do: x
        end
        """,
        "go"
      )

    assert %Type{kind: :ref, ref: "a"} = root
    assert Map.keys(defs) |> Enum.sort() == ["a", "b"]

    assert defs["b"].fields |> Enum.find(&(&1.name == "a")) |> Map.fetch!(:type) ==
             %Type{kind: :ref, ref: "a"}
  end

  test "parameterized recursion names instantiations by argument" do
    %Tool{defs: defs, params: [%Param{type: root}]} =
      tool(
        """
        defmodule FIXTURE do
          use ToolCall
          @type tree(a) :: %{value: a, children: [tree(a)]}
          @doc "Go."
          @spec go(x :: tree(integer())) :: map()
          def go(x), do: x
        end
        """,
        "go"
      )

    assert %Type{kind: :ref, ref: "tree_integer"} = root
    assert Map.has_key?(defs, "tree_integer")
  end

  test "readable name collisions get distinct definitions" do
    %Tool{defs: defs, params: [first, second]} =
      tool(
        """
        defmodule FIXTURE do
          use ToolCall
          @type tree(a) :: %{value: a, children: [tree(a)]}
          @doc "Go."
          @spec go(one :: tree(integer()), two :: tree(pos_integer())) :: map()
          def go(one, two), do: {one, two}
        end
        """,
        "go"
      )

    assert %Type{kind: :ref, ref: one_ref} = first.type
    assert %Type{kind: :ref, ref: two_ref} = second.type
    refute one_ref == two_ref
    assert Map.has_key?(defs, one_ref)
    assert Map.has_key?(defs, two_ref)
  end

  test "recursion under tuple, union and map values" do
    %Tool{defs: defs, params: [%Param{type: %Type{kind: :ref, ref: "shape"}}]} =
      tool(@shapes, "go")

    fields = defs["shape"].fields

    assert %Type{kind: :tuple, items: [%Type{kind: :ref}, %Type{kind: :integer}]} =
             Enum.find(fields, &(&1.name == "pair")).type

    assert %Type{kind: :enum} = Enum.find(fields, &(&1.name == "kind")).type

    assert %Type{kind: :object, additional: %Type{kind: :ref, ref: "shape"}} =
             Enum.find(fields, &(&1.name == "peers")).type
  end

  test "ref names are stable across compiles" do
    one = tool(@tree, "walk")
    two = tool(@tree, "walk")

    assert Map.keys(one.defs) == Map.keys(two.defs)
    assert hd(one.params).type == hd(two.params).type
  end

  test "unused recursive types do not enter defs" do
    %Tool{defs: defs} =
      tool(
        """
        defmodule FIXTURE do
          use ToolCall
          @type tree :: %{children: [tree()]}
          @doc "Go."
          @spec go(x :: integer()) :: map()
          def go(x), do: x
        end
        """,
        "go"
      )

    assert defs == %{}
  end

  test "validate_tool!/1 rejects a dangling ref" do
    bad = %Tool{name: "go", description: "Go.", params: [], defs: %{}}
    good_ref = %Param{name: "x", type: %Type{kind: :ref, ref: "missing"}, required: true}

    assert_raise ArgumentError, ~r/unknown \$defs entry/, fn ->
      ToolCall.Typespec.validate_tool!(%{bad | params: [good_ref]})
    end
  end

  defp params(source, name, opts \\ []) do
    module = compile!(source)

    module
    |> ToolCall.emit(:openai, opts)
    |> Enum.find(&(&1["function"]["name"] == name))
    |> get_in(["function", "parameters"])
  end

  test "emits $ref and $defs" do
    params = params(@tree, "walk")

    assert params["properties"]["root"] == %{"$ref" => "#/$defs/tree"}
    assert params["$defs"]["tree"]["additionalProperties"] == false
    assert Enum.sort(params["$defs"]["tree"]["required"]) == ["children", "value"]
  end

  test "emits $defs for anthropic without the openai envelope" do
    module = compile!(@tree)
    [tool] = ToolCall.emit(module, :anthropic)

    assert tool["input_schema"]["properties"]["root"] == %{"$ref" => "#/$defs/tree"}
    assert Map.has_key?(tool["input_schema"], "$defs")
  end

  test "strict mode closes and requires everything inside $defs" do
    params = params(@tree, "walk", strict: true)
    tree = params["$defs"]["tree"]

    assert tree["additionalProperties"] == false
    assert Enum.sort(tree["required"]) == ["children", "value"]
  end

  test "a nullable recursive type renders anyOf with null" do
    params =
      params(
        """
        defmodule FIXTURE do
          use ToolCall
          @type tree :: %{children: [tree()]}
          @doc "Go."
          @spec go(root :: tree() | nil) :: map()
          def go(root), do: root
        end
        """,
        "go"
      )

    assert %{"anyOf" => [%{"$ref" => "#/$defs/tree"}, %{"type" => "null"}]} =
             params["properties"]["root"]
  end

  test "describe/2 carries the same $defs" do
    module = compile!(@tree)
    [spec] = ToolCall.describe(module)

    assert spec.parameters["properties"]["root"] == %{"$ref" => "#/$defs/tree"}
    assert Map.has_key?(spec.parameters, "$defs")
  end

  defp run(source, name, args) do
    module = compile!(source)
    ToolCall.run(module, name, args)
  end

  test "coerces a recursive value at every level" do
    assert {:ok, %{value: 1, children: [%{value: 2, children: []}]}} =
             run(@tree, :walk, %{
               "root" => %{"value" => 1, "children" => [%{"value" => 2, "children" => []}]}
             })
  end

  test "rejects atom keys deep inside a recursive value" do
    assert {:error, {:non_string_arguments, [:value]}} =
             run(@tree, :walk, %{"root" => %{"value" => 1, "children" => [%{value: 2}]}})
  end

  test "rejects a malformed deep value" do
    assert {:error,
            {:invalid_argument, {"root", {"children", {0, {"value", {:expected_integer, "x"}}}}}}} =
             run(@tree, :walk, %{
               "root" => %{"value" => 1, "children" => [%{"value" => "x", "children" => []}]}
             })
  end
end
