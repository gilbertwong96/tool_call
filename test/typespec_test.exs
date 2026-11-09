defmodule ToolCall.TypespecTest do
  use ExUnit.Case, async: true

  alias ToolCall.IR.{Field, Type}
  alias ToolCall.Typespec

  defp ir(ast), do: Typespec.to_type(ast)

  test "scalar types" do
    assert %Type{kind: :integer, minimum: nil} = ir({:integer, [], []})
    assert %Type{kind: :integer, minimum: 0} = ir({:non_neg_integer, [], []})
    assert %Type{kind: :integer, minimum: 1} = ir({:pos_integer, [], []})
    assert %Type{kind: :integer, maximum: -1} = ir({:neg_integer, [], []})
    assert %Type{kind: :integer, minimum: 0, maximum: 255} = ir({:byte, [], []})
    assert %Type{kind: :float} = ir({:float, [], []})
    assert %Type{kind: :number} = ir({:number, [], []})
    assert %Type{kind: :string} = ir({:binary, [], []})
    assert %Type{kind: :string, pattern: "^[\\s\\S]$"} = ir({:char, [], []})
    assert %Type{kind: :boolean} = ir({:boolean, [], []})
    assert %Type{kind: :atom} = ir({:atom, [], []})
  end

  test "literal atoms become enums" do
    assert %Type{kind: :enum, values: [:red, :green]} = ir({:|, [], [:red, :green]})
  end

  test "a nil union becomes a nullable type" do
    assert %Type{kind: :integer, nullable: true} = ir({:|, [], [{:integer, [], []}, nil]})
  end

  test "a union of only nulls stays nullable" do
    assert %Type{kind: :union, variants: [], nullable: true} = ir({:|, [], [nil, nil]})
  end

  test "a union of boolean literals stays an enum" do
    assert %Type{kind: :enum, values: [true, false]} = ir({:|, [], [true, false]})
  end

  test "unions of the same kind collapse" do
    # `integer()` is unbounded on both sides, so the union stays unbounded.
    assert %Type{kind: :integer, minimum: nil, maximum: nil} =
             ir({:|, [], [{:integer, [], []}, {:non_neg_integer, [], []}]})

    assert %Type{kind: :integer, minimum: 0, maximum: nil} =
             ir({:|, [], [{:non_neg_integer, [], []}, {:pos_integer, [], []}]})
  end

  test "mixed unions stay as variants" do
    assert %Type{kind: :union, variants: [integer, enum]} =
             ir({:|, [], [{:integer, [], []}, {:|, [], [:a, :b]}]})

    assert integer.kind == :integer
    assert enum.values == [:a, :b]
  end

  test "a range with a non-literal bound degrades to any" do
    assert %Type{kind: :any} = ir({:.., [], [1.0, 2]})
  end

  test "nonempty_list/0 has an unconstrained item type" do
    assert %Type{kind: :array, items: %Type{kind: :any}, minimum: 1} =
             ir({:nonempty_list, [], []})
  end

  test "a union of scalar kinds keeps the first" do
    assert %Type{kind: :atom} = ir({:|, [], [{:atom, [], []}, {:module, [], []}]})
  end

  test "integer ranges become bounds" do
    assert %Type{kind: :integer, minimum: 1, maximum: 10} = ir({:.., [], [1, 10]})
  end

  test "negative integer literals and ranges keep their bounds" do
    assert %Type{kind: :integer, minimum: -10, maximum: -10} = ir({:-, [], [10]})

    assert %Type{kind: :integer, minimum: -90, maximum: 90} =
             ir({:.., [], [{:-, [], [90]}, 90]})

    assert %Type{kind: :integer, minimum: -10, maximum: -1} =
             ir({:.., [], [{:-, [], [10]}, {:-, [], [1]}]})
  end

  test "integer literals become an enum" do
    assert %Type{kind: :enum, values: [1, 2]} = ir({:|, [], [1, 2]})
  end

  test "object fields keep the atom key of the value domain" do
    ast =
      {:%{}, [],
       [
         {:name, {:binary, [], []}},
         {{:optional, [], [:age]}, {:integer, [], []}}
       ]}

    assert %Type{
             fields: [
               %Field{name: "name", key: :name, required: true},
               %Field{name: "age", key: :age, required: false}
             ]
           } = ir(ast)
  end

  test "maps split required and optional fields" do
    ast =
      {:%{}, [],
       [
         {:name, {:binary, [], []}},
         {{:optional, [], [:age]}, {:integer, [], []}}
       ]}

    assert %Type{kind: :object, fields: [name, age]} = ir(ast)
    assert name.name == "name"
    assert name.required
    assert age.name == "age"
    refute age.required
  end

  test "required/1 keys behave like atom keys" do
    ast =
      {:%{}, [],
       [
         {{:required, [], [:k]}, {:integer, [], []}},
         {{:optional, [], [:o]}, {:binary, [], []}}
       ]}

    assert %Type{kind: :object, fields: [k, o], additional: nil} = ir(ast)
    assert k.name == "k"
    assert k.required
    refute o.required
  end

  test "typed required keys stay open, because JSON Schema has no key types" do
    ast = {:%{}, [], [{{:required, [], [{{:., [], [String, :t]}, [], []}]}, {:integer, [], []}}]}

    assert %Type{kind: :object, fields: [], additional: %Type{kind: :integer}} = ir(ast)
  end

  test "a malformed Keyword.t arity degrades to any" do
    assert %Type{kind: :any} =
             ir({{:., [], [Keyword, :t]}, [], [{:integer, [], []}, {:binary, [], []}]})
  end

  test "open maps keep the value type as additionalProperties" do
    ast = {:%{}, [], [{{{:., [], [String, :t]}, [], []}, {:integer, [], []}}]}

    assert %Type{kind: :object, fields: [], additional: %Type{kind: :integer}} = ir(ast)
  end

  test "lists become arrays" do
    assert %Type{kind: :array, items: %Type{kind: :integer}} = ir([{:integer, [], []}])

    assert %Type{kind: :array, items: %Type{kind: :integer}} =
             ir({:list, [], [{:integer, [], []}]})

    assert %Type{kind: :array, minimum: 1} = ir({:nonempty_list, [], [{:integer, [], []}]})
  end

  test "tuples keep their arity" do
    assert %Type{kind: :tuple, items: [%Type{kind: :integer}, %Type{kind: :string}]} =
             ir({:{}, [], [{:integer, [], []}, {:binary, [], []}]})

    assert %Type{kind: :tuple, items: [_, _]} =
             ir({{:integer, [], []}, {:binary, [], []}})
  end

  test "remote types" do
    assert %Type{kind: :string} = ir({{:., [], [String, :t]}, [], []})
    assert %Type{kind: :object} = ir({{:., [], [Keyword, :t]}, [], []})
    assert %Type{kind: :string} = ir({{:., [], [Date, :t]}, [], []})
    assert %Type{kind: :any} = ir({{:., [], [SomeUnknown, :t]}, [], []})
  end

  test "built-in providers only match t/0" do
    assert %Type{kind: :any} = ir({{:., [], [String, :foo]}, [], []})
    assert %Type{kind: :any} = ir({{:., [], [Path, :foo]}, [], []})
    assert %Type{kind: :any} = ir({{:., [], [Date, :foo]}, [], []})
  end

  test "literal values" do
    assert %Type{kind: :null} = ir(nil)
    assert %Type{kind: :enum, values: [true]} = ir(true)
    assert %Type{kind: :enum, values: [false]} = ir(false)
    assert %Type{kind: :enum, values: [:red]} = ir(:red)
    assert %Type{kind: :integer, minimum: 7, maximum: 7} = ir(7)
    assert %Type{kind: :float} = ir(1.5)
  end

  test "the empty list is an unconstrained array" do
    assert %Type{kind: :array, items: %Type{kind: :any}} = ir([])
  end

  test "scalar aliases" do
    assert %Type{kind: :atom} = ir({:module, [], []})
    assert %Type{kind: :string, source: :string} = ir({:string, [], []})
    assert %Type{kind: :string, source: :charlist} = ir({:charlist, [], []})
    assert %Type{kind: :string, source: :bitstring} = ir({:bitstring, [], []})
    assert %Type{kind: :string, source: :string} = ir({:nonempty_string, [], []})
    assert %Type{kind: :array, items: %Type{kind: :any}} = ir({:list, [], []})
    assert %Type{kind: :tuple, items: nil} = ir({:tuple, [], []})
    assert %Type{kind: :object, additional: %Type{kind: :any}} = ir({:map, [], []})
    assert %Type{kind: :object, additional: %Type{kind: :any}} = ir({:keyword, [], []})
    assert %Type{kind: :object, additional: %Type{kind: :any}} = ir({:struct, [], []})
  end

  test "as_boolean unwraps or degrades to boolean" do
    assert %Type{kind: :integer} = ir({:as_boolean, [], [{:integer, [], []}]})
    assert %Type{kind: :boolean} = ir({:as_boolean, [], []})
  end

  test "calendar and path types travel as strings" do
    for module <- [Date, Time, DateTime, NaiveDateTime, Path] do
      assert %Type{kind: :string, source: {^module, :t}} =
               ir({{:., [], [module, :t]}, [], []})
    end
  end

  test "Keyword.t/1 keeps its value type" do
    assert %Type{kind: :object, additional: %Type{kind: :integer}} =
             ir({{:., [], [Keyword, :t]}, [], [{:integer, [], []}]})
  end

  test "validate_type!/1 rejects negative array bounds" do
    assert_raise ArgumentError, ~r/array minimum must be >= 0/, fn ->
      Typespec.validate_type!(%Type{kind: :array, minimum: -1})
    end

    assert_raise ArgumentError, ~r/array maximum must be >= 0/, fn ->
      Typespec.validate_type!(%Type{kind: :array, maximum: -1})
    end

    assert %Type{kind: :array, minimum: 1, maximum: 2} =
             Typespec.validate_type!(%Type{kind: :array, minimum: 1, maximum: 2})
  end

  test "validate_type!/1 rejects empty non-nullable unions and duplicate fields" do
    assert_raise ArgumentError, ~r/variants/, fn ->
      Typespec.validate_type!(%Type{kind: :union, variants: []})
    end

    assert %Type{kind: :union, variants: [], nullable: true} =
             Typespec.validate_type!(%Type{kind: :union, variants: [], nullable: true})

    field = %Field{name: "x", key: :x, type: %Type{kind: :string}}

    assert_raise ArgumentError, ~r/duplicate field names/, fn ->
      Typespec.validate_type!(%Type{kind: :object, fields: [field, field]})
    end

    other = %Field{name: "y", key: :x, type: %Type{kind: :string}}

    assert_raise ArgumentError, ~r/duplicate field keys/, fn ->
      Typespec.validate_type!(%Type{kind: :object, fields: [field, other]})
    end
  end

  test "validate_type!/1 rejects invalid UTF-8 metadata" do
    assert_raise ArgumentError, ~r/format must be valid UTF-8/, fn ->
      Typespec.validate_type!(%Type{kind: :string, format: <<255>>})
    end

    assert_raise ArgumentError, ~r/pattern must be valid UTF-8/, fn ->
      Typespec.validate_type!(%Type{kind: :string, pattern: <<255>>})
    end

    assert_raise ArgumentError, ~r/enum values must be valid UTF-8/, fn ->
      Typespec.validate_type!(%Type{kind: :enum, values: [<<255>>]})
    end

    assert_raise ArgumentError, ~r/field name must be valid UTF-8/, fn ->
      Typespec.validate_type!(%Type{
        kind: :object,
        fields: [%Field{name: <<255>>, key: :x, type: %Type{kind: :string}}]
      })
    end
  end

  test "default_compatible?/2 covers value domains" do
    assert Typespec.default_compatible?(%Type{kind: :float, minimum: 1.0}, 1.5)
    refute Typespec.default_compatible?(%Type{kind: :float}, 1)
    assert Typespec.default_compatible?(%Type{kind: :number}, 1)
    assert Typespec.default_compatible?(%Type{kind: :atom}, :ok)
    refute Typespec.default_compatible?(%Type{kind: :atom}, true)
    refute Typespec.default_compatible?(%Type{kind: :atom}, false)
    refute Typespec.default_compatible?(%Type{kind: :atom}, nil)
    refute Typespec.default_compatible?(%Type{kind: :atom, nullable: true}, nil)
    refute Typespec.default_compatible?(%Type{kind: :atom, nullable: true}, true)
    assert Typespec.default_compatible?(%Type{kind: :null}, nil)
    assert Typespec.default_compatible?(%Type{kind: :enum, values: [:a]}, :a)
    refute Typespec.default_compatible?(%Type{kind: :enum, values: [:a]}, :b)

    assert Typespec.default_compatible?(
             %Type{kind: :string, transform: {SomeModule, :coerce}},
             :anything
           )

    assert Typespec.default_compatible?(%Type{kind: :string, pattern: "^x$"}, "x")
    refute Typespec.default_compatible?(%Type{kind: :string, pattern: "["}, "x")
    refute Typespec.default_compatible?(%Type{kind: :string, pattern: :bad}, "x")
    refute Typespec.default_compatible?(%Type{kind: :unsupported}, "x")
  end

  test "default_compatible?/2 validates tuple shape and object fields" do
    tuple = %Type{kind: :tuple, items: [%Type{kind: :integer}, %Type{kind: :integer}]}

    assert Typespec.default_compatible?(tuple, [1, 2])
    refute Typespec.default_compatible?(tuple, [1])
    refute Typespec.default_compatible?(tuple, [1, "x"])
    assert Typespec.default_compatible?(%Type{kind: :tuple, items: nil}, [1, 2])
    refute Typespec.default_compatible?(%Type{kind: :tuple, items: :not_a_list}, [1])

    object = %Type{
      kind: :object,
      fields: [
        %Field{name: "a", key: :a, type: %Type{kind: :integer}},
        %Field{name: "b", key: :b, type: %Type{kind: :integer}}
      ],
      additional: nil
    }

    assert Typespec.default_compatible?(object, %{a: 1, b: 2})
    refute Typespec.default_compatible?(object, %{a: 1})
    refute Typespec.default_compatible?(object, %{a: 1, b: "x"})
    refute Typespec.default_compatible?(object, %{a: 1, b: 2, c: 3})

    assert Typespec.default_compatible?(
             %Type{
               kind: :object,
               fields: [%Field{name: "a", key: nil, type: %Type{kind: :integer}}],
               additional: nil
             },
             %{"a" => 1}
           )

    refute Typespec.default_compatible?(
             %Type{kind: :object, fields: [], additional: :invalid},
             %{}
           )

    refute Typespec.default_compatible?(
             %Type{
               kind: :object,
               source: :keyword,
               additional: %Type{kind: :integer}
             },
             %{"a" => 1}
           )
  end

  test "default_compatible?/2 accepts nil for nullable values" do
    nullable_integer = %Type{kind: :integer, nullable: true}

    assert Typespec.default_compatible?(nullable_integer, nil)

    assert Typespec.default_compatible?(
             %Type{kind: :array, items: nullable_integer},
             [nil, 1]
           )

    assert Typespec.default_compatible?(
             %Type{
               kind: :object,
               fields: [%Field{name: "a", key: :a, type: nullable_integer}],
               additional: nil
             },
             %{a: nil}
           )
  end

  test "validate_tool!/1 rejects defaults outside the parameter domain" do
    param = %ToolCall.IR.Param{name: "x", type: %Type{kind: :integer}, default: "x"}

    assert_raise ArgumentError, ~r/default.*not compatible/, fn ->
      Typespec.validate_tool!(%ToolCall.IR.Tool{name: "go", params: [param]})
    end

    empty = %ToolCall.IR.Param{
      name: "b",
      type: %Type{kind: :string, pattern: "^[\\s\\S]+$"},
      default: ""
    }

    assert_raise ArgumentError, ~r/default.*not compatible/, fn ->
      Typespec.validate_tool!(%ToolCall.IR.Tool{name: "go", params: [empty]})
    end
  end

  test "validate_tool!/1 rejects invalid UTF-8 names, descriptions and defaults" do
    base = %ToolCall.IR.Param{name: "x", type: %Type{kind: :string}}

    assert_raise ArgumentError, ~r/tool name must be valid UTF-8/, fn ->
      Typespec.validate_tool!(%ToolCall.IR.Tool{name: <<255>>, params: []})
    end

    assert_raise ArgumentError, ~r/parameter name must be valid UTF-8/, fn ->
      Typespec.validate_tool!(%ToolCall.IR.Tool{
        name: "go",
        params: [%{base | name: <<255>>}]
      })
    end

    assert_raise ArgumentError, ~r/description must be valid UTF-8/, fn ->
      Typespec.validate_tool!(%ToolCall.IR.Tool{
        name: "go",
        description: <<255>>,
        params: []
      })
    end

    assert_raise ArgumentError, ~r/default must be JSON-encodable/, fn ->
      Typespec.validate_tool!(%ToolCall.IR.Tool{
        name: "go",
        params: [%{base | default: <<255>>}]
      })
    end

    assert_raise ArgumentError, ~r/default must be JSON-encodable/, fn ->
      Typespec.validate_tool!(%ToolCall.IR.Tool{
        name: "go",
        params: [%{base | default: %{<<255>> => "x"}}]
      })
    end
  end

  test "validate_tool!/1 rejects duplicate parameter names and invalid wire types" do
    param = %ToolCall.IR.Param{name: "x", type: %Type{kind: :integer}}

    assert_raise ArgumentError, ~r/duplicate parameter names/, fn ->
      Typespec.validate_tool!(%ToolCall.IR.Tool{name: "go", params: [param, param]})
    end

    bad_wire = %ToolCall.IR.Param{name: "x", wire: :string_integer, type: %Type{kind: :string}}

    assert_raise ArgumentError, ~r/wire :string_integer requires an integer/, fn ->
      Typespec.validate_tool!(%ToolCall.IR.Tool{name: "go", params: [bad_wire]})
    end
  end

  test "validate_tool!/1 rejects a non-tool" do
    assert_raise ArgumentError, ~r/expected a tool/, fn ->
      Typespec.validate_tool!(:not_a_tool)
    end
  end

  test "unknown remote types keep their source" do
    assert %Type{kind: :any, source: {SomeUnknown, :t, []}} =
             ir({{:., [], [SomeUnknown, :t]}, [], []})

    assert %Type{kind: :any, source: {SomeUnknown, :t, [{:integer, [], []}]}} =
             ir({{:., [], [SomeUnknown, :t]}, [], [{:integer, [], []}]})
  end

  test "same-kind unions merge their bounds only when the merge is exact" do
    # 0..10 ∪ 1..∞ is 0..∞: the unbounded variant must not be truncated.
    assert %Type{kind: :integer, minimum: 0, maximum: nil} =
             ir({:|, [], [{:.., [], [0, 10]}, {:pos_integer, [], []}]})

    # A contained range adds nothing.
    assert %Type{kind: :integer, minimum: 0, maximum: 255} =
             ir({:|, [], [{:byte, [], []}, {:.., [], [1, 10]}]})

    # Adjacent ranges have no hole between them.
    assert %Type{kind: :integer, minimum: 1, maximum: 20} =
             ir({:|, [], [{:.., [], [1, 10]}, {:.., [], [11, 20]}]})
  end

  test "keyword/2 degrades instead of raising" do
    assert %Type{kind: :any, source: {:keyword, [_, _]}} =
             ir({:keyword, [], [{:atom, [], []}, {:integer, [], []}]})
  end

  test "disjoint integer ranges stay variants" do
    assert %Type{
             kind: :union,
             variants: [%Type{minimum: 1, maximum: 10}, %Type{minimum: 20, maximum: 30}]
           } =
             ir({:|, [], [{:.., [], [1, 10]}, {:.., [], [20, 30]}]})

    assert %Type{kind: :union, variants: [%Type{minimum: 1}, %Type{maximum: -1}]} =
             ir({:|, [], [{:pos_integer, [], []}, {:neg_integer, [], []}]})
  end

  test "structural unions are not collapsed by kind" do
    assert %Type{kind: :union, variants: [%Type{kind: :array}, %Type{kind: :array}]} =
             ir({:|, [], [[{:integer, [], []}], [{:binary, [], []}]]})

    assert %Type{kind: :union, variants: [%Type{kind: :object}, %Type{kind: :object}]} =
             ir(
               {:|, [], [{:%{}, [], [a: {:binary, [], []}]}, {:%{}, [], [b: {:integer, [], []}]}]}
             )
  end

  test "any unknown shape degrades to any" do
    assert %Type{kind: :any} = ir({:__block__, [], [1, 2]})
    assert %Type{kind: :any, source: %{}} = ir(%{})
  end

  test "unrepresentable domains are flagged, unknown ones degrade" do
    assert %Type{kind: :unsupported} = ir({:pid, [], []})
    assert %Type{kind: :unsupported} = ir([{:->, [], [[], {:integer, [], []}]}])

    assert %Type{kind: :unsupported} =
             ir({:fun, [], [{:->, [], [[{:integer, [], []}], {:integer, [], []}]}]})

    assert %Type{kind: :any} = ir({:term, [], []})
    assert %Type{kind: :any} = ir({:some_unknown_type, [], []})
    assert %Type{kind: :string} = ir({:nonempty_binary, [], []})
  end

  describe "struct validation" do
    test "rejects an object whose struct is not a struct module" do
      assert_raise ArgumentError, ~r/__struct__\/0/, fn ->
        Typespec.validate_type!(%Type{kind: :object, struct: :not_a_module})
      end
    end

    test "accepts a struct module and a plain map object" do
      assert %Type{kind: :object, struct: Date} =
               Typespec.validate_type!(%Type{kind: :object, struct: Date})

      assert %Type{kind: :object, struct: nil} =
               Typespec.validate_type!(%Type{kind: :object, struct: nil})
    end
  end

  test "rejects a malformed validator on a hand-built type" do
    assert_raise ArgumentError, ~r/validator/, fn ->
      Typespec.validate_type!(%Type{kind: :string, validator: {Date, :nope}})
    end

    assert_raise ArgumentError, ~r/validator/, fn ->
      Typespec.validate_type!(%Type{kind: :string, validator: :not_a_pair})
    end
  end

  test "accepts a valid validator" do
    assert %Type{validator: {Date, :to_iso8601}} =
             Typespec.validate_type!(%Type{kind: :string, validator: {Date, :to_iso8601}})
  end
end
