defmodule ToolCall.ValidateTest do
  use ExUnit.Case, async: true

  alias ToolCall.IR.{Field, Type}
  alias ToolCall.Validate

  defmodule Raising do
    def validate(_type, _value, _defs), do: raise("boom")
  end

  defp int(min \\ nil, max \\ nil), do: %Type{kind: :integer, minimum: min, maximum: max}
  defp str(source \\ nil), do: %Type{kind: :string, source: source}

  defp field(name, type, required) do
    %Field{name: Atom.to_string(name), key: name, type: type, required: required}
  end

  test "nil is valid on a nullable node before any other rule" do
    assert :ok = Validate.valid?(%Type{kind: :integer, nullable: true}, nil, %{})

    assert :ok =
             Validate.valid?(
               %Type{kind: :string, validator: {String, :valid?}, nullable: true},
               nil,
               %{}
             )
  end

  test "binary, bitstring and nonempty_binary use their value domains" do
    assert :ok = Validate.valid?(str(:binary), <<255>>, %{})
    assert :ok = Validate.valid?(str(:bitstring), <<1::1>>, %{})
    assert :ok = Validate.valid?(str(:nonempty_binary), "x", %{})

    assert {:error, {:invalid_utf8, <<255>>}} = Validate.valid?(str(), <<255>>, %{})
    assert {:error, _} = Validate.valid?(str(:nonempty_binary), "", %{})
  end

  test "char and charlist use codepoints and lists" do
    assert :ok = Validate.valid?(str(:char), ?A, %{})
    assert {:error, _} = Validate.valid?(str(:char), "A", %{})
    assert :ok = Validate.valid?(str(:charlist), ~c"abc", %{})
    assert {:error, _} = Validate.valid?(str(:charlist), "abc", %{})
  end

  test "char and charlist reject invalid Unicode codepoints" do
    assert {:error, {:expected_char, 0xD800}} = Validate.valid?(str(:char), 0xD800, %{})

    assert {:error, {:expected_charlist, [0x110000]}} =
             Validate.valid?(str(:charlist), [0x110000], %{})

    assert {:error, {:expected_charlist, [0xD800]}} =
             Validate.valid?(str(:charlist), [0xD800], %{})
  end

  test "a validator replaces the kind rule" do
    node = %Type{kind: :string, validator: {ToolCall.Providers.Stdlib, :validate_date}}

    assert :ok = Validate.valid?(node, ~D[2024-01-01], %{})

    assert {:error, {:validator, {ToolCall.Providers.Stdlib, :validate_date}, "2024-01-01"}} =
             Validate.valid?(node, "2024-01-01", %{})
  end

  test "a transform-only provider node is accepted" do
    node = %Type{kind: :string, transform: {ToolCall.Providers.Stdlib, :coerce_date}}
    assert :ok = Validate.valid?(node, "anything", %{})
  end

  test "a raising validator is reported, not raised" do
    node = %Type{kind: :string, validator: {Raising, :validate}}
    assert {:error, {:validate_raised, "boom"}} = Validate.valid?(node, "x", %{})
  end

  test "integer bounds" do
    assert :ok = Validate.valid?(int(1, 3), 2, %{})
    assert {:error, {:below_minimum, 0, 1}} = Validate.valid?(int(1, 3), 0, %{})
    assert {:error, {:above_maximum, 4, 3}} = Validate.valid?(int(1, 3), 4, %{})
    assert {:error, {:expected_integer, 1.0}} = Validate.valid?(int(), 1.0, %{})
  end

  test "float requires a float; number accepts both" do
    assert :ok = Validate.valid?(%Type{kind: :float}, 1.0, %{})
    assert {:error, {:expected_float, 1}} = Validate.valid?(%Type{kind: :float}, 1, %{})
    assert :ok = Validate.valid?(%Type{kind: :number}, 1, %{})
    assert :ok = Validate.valid?(%Type{kind: :number}, 1.0, %{})
  end

  test "string patterns and utf8" do
    node = %Type{kind: :string, pattern: "^a+$", pattern_regex: ~r/^a+$/}
    assert :ok = Validate.valid?(node, "aaa", %{})
    assert {:error, {:pattern_mismatch, "^a+$", "b"}} = Validate.valid?(node, "b", %{})
  end

  test "boolean, atom and enum value domains" do
    assert :ok = Validate.valid?(%Type{kind: :boolean}, true, %{})

    assert {:error, {:expected_boolean, :ok}} =
             Validate.valid?(%Type{kind: :boolean}, :ok, %{})

    assert :ok = Validate.valid?(%Type{kind: :atom}, true, %{})
    assert :ok = Validate.valid?(%Type{kind: :atom}, :ok, %{})

    enum = %Type{kind: :enum, values: [true, :a]}
    assert :ok = Validate.valid?(enum, true, %{})
    assert :ok = Validate.valid?(enum, :a, %{})
    assert {:error, {:invalid_enum, "a", [true, :a]}} = Validate.valid?(enum, "a", %{})
  end

  test "empty enums follow their string wire domain" do
    assert :ok = Validate.valid?(%Type{kind: :enum, values: []}, "x", %{})
    assert :ok = Validate.valid?(%Type{kind: :enum, values: nil}, "x", %{})

    assert {:error, {:invalid_utf8, <<255>>}} =
             Validate.valid?(%Type{kind: :enum, values: []}, <<255>>, %{})

    assert {:error, {:invalid_enum, 1, []}} =
             Validate.valid?(%Type{kind: :enum, values: []}, 1, %{})
  end

  test "null, any and unsupported" do
    assert :ok = Validate.valid?(%Type{kind: :null}, nil, %{})
    assert {:error, _} = Validate.valid?(%Type{kind: :null}, 1, %{})
    assert :ok = Validate.valid?(%Type{kind: :any}, :anything, %{})
    assert :ok = Validate.valid?(%Type{kind: :unsupported}, self(), %{})
  end

  test "arrays check items, bounds and index paths" do
    node = %Type{kind: :array, items: int(), minimum: 1}

    assert :ok = Validate.valid?(node, [1, 2], %{})
    assert {:error, {:too_few_items, 0, 1}} = Validate.valid?(node, [], %{})

    assert {:error, {:too_many_items, 2, 1}} =
             Validate.valid?(%Type{kind: :array, items: int(), maximum: 1}, [1, 2], %{})

    assert :ok = Validate.valid?(%Type{kind: :array, items: int(), maximum: 2}, [1, 2], %{})
    assert {:error, {0, {:expected_integer, "x"}}} = Validate.valid?(node, ["x"], %{})
    assert {:error, {:expected_array, "x"}} = Validate.valid?(node, "x", %{})
  end

  test "tuples check size and elements" do
    node = %Type{kind: :tuple, items: [int(), str()]}

    assert :ok = Validate.valid?(node, {1, "x"}, %{})
    assert {:error, {:wrong_tuple_size, 1, 2}} = Validate.valid?(node, {1}, %{})
    assert {:error, {0, {:expected_integer, "x"}}} = Validate.valid?(node, {"x", "y"}, %{})
    assert :ok = Validate.valid?(%Type{kind: :tuple, items: nil}, {1, 2, 3}, %{})
    assert {:error, {:expected_tuple, [1, "x"]}} = Validate.valid?(node, [1, "x"], %{})
  end

  test "nullable enum, ref and union accept nil" do
    defs = %{"t" => int()}

    for node <- [
          %Type{kind: :enum, values: [:idle], nullable: true},
          %Type{kind: :ref, ref: "t", nullable: true},
          %Type{kind: :union, variants: [int()], nullable: true}
        ] do
      assert :ok = Validate.valid?(node, nil, defs)

      assert {:error, _reason} =
               Validate.valid?(node, :not_valid_for_all, defs)
               |> then(fn
                 :ok -> {:error, :accepted}
                 error -> error
               end)
    end
  end

  test "a struct object checks the struct, required fields and field types" do
    node = %Type{
      kind: :object,
      struct: ToolCall.TestFixtures.Address,
      fields: [field(:city, str(), true)],
      additional: nil
    }

    assert :ok =
             Validate.valid?(node, %ToolCall.TestFixtures.Address{city: "Oslo"}, %{})

    assert {:error, {:expected_struct, %{city: "Oslo"}}} =
             Validate.valid?(node, %{city: "Oslo"}, %{})

    assert {:error, {"city", {:expected_string, 1}}} =
             Validate.valid?(node, %ToolCall.TestFixtures.Address{city: 1, country: "NO"}, %{})
  end

  test "a closed object rejects extra keys" do
    node = %Type{kind: :object, fields: [field(:a, int(), true)], additional: nil}

    assert :ok = Validate.valid?(node, %{a: 1}, %{})
    assert {:error, {:unknown_keys, ["b"]}} = Validate.valid?(node, %{a: 1, b: 2}, %{})
    assert {:error, {:missing_field, "a"}} = Validate.valid?(node, %{}, %{})
    assert {:error, {"a", {:expected_integer, "x"}}} = Validate.valid?(node, %{a: "x"}, %{})
  end

  test "an open object accepts extra keys" do
    node = %Type{kind: :object, fields: [], additional: %Type{kind: :any}}
    assert :ok = Validate.valid?(node, %{anything: 1}, %{})
  end

  test "unions accept any matching variant" do
    node = %Type{kind: :union, variants: [int(), str()]}

    assert :ok = Validate.valid?(node, 1, %{})
    assert :ok = Validate.valid?(node, "x", %{})
    assert {:error, {:no_variant_matched, :atom}} = Validate.valid?(node, :atom, %{})
  end

  test "refs resolve through defs, including recursive ones" do
    tree = %Type{
      kind: :object,
      fields: [
        field(:value, int(), true),
        field(:children, %Type{kind: :array, items: %Type{kind: :ref, ref: "tree"}}, true)
      ],
      additional: nil
    }

    defs = %{"tree" => tree}
    node = %Type{kind: :ref, ref: "tree"}

    assert :ok = Validate.valid?(node, %{value: 1, children: [%{value: 2, children: []}]}, defs)

    assert {:error, {"children", {0, {"value", {:expected_integer, "x"}}}}} =
             Validate.valid?(node, %{value: 1, children: [%{value: "x", children: []}]}, defs)
  end

  test "a missing ref raises an IR error" do
    assert_raise ArgumentError, ~r/unknown \$defs entry/, fn ->
      Validate.valid?(%Type{kind: :ref, ref: "missing"}, 1, %{})
    end
  end

  defp type(ast), do: ToolCall.Typespec.to_type(ast)

  defp date_t, do: type({{:., [], [Date, :t]}, [], []})
  defp mapset_t, do: type({{:., [], [MapSet, :t]}, [], [{:integer, [], []}]})
  defp keyword_t, do: type({:keyword, [], [{:integer, [], []}]})

  test "Date.t() accepts a struct and rejects its string form" do
    assert :ok = Validate.valid?(date_t(), ~D[2024-01-01], %{})

    assert {:error, {:validator, {ToolCall.Providers.Stdlib, :validate_date}, "2024-01-01"}} =
             Validate.valid?(date_t(), "2024-01-01", %{})
  end

  test "MapSet.t() accepts the struct and rejects a list" do
    assert :ok = Validate.valid?(mapset_t(), MapSet.new([1, 2]), %{})

    assert {:error, {:validator, {ToolCall.Providers.MapSet, :validate}, [1, 2]}} =
             Validate.valid?(mapset_t(), [1, 2], %{})
  end

  test "Keyword.t() accepts a keyword list and rejects a map" do
    assert :ok = Validate.valid?(keyword_t(), [a: 1], %{})

    assert {:error, {:validator, {ToolCall.Providers.Stdlib, :validate_keyword}, %{"a" => 1}}} =
             Validate.valid?(keyword_t(), %{"a" => 1}, %{})
  end

  test "Regex.t() validates a compiled regex" do
    regex_t = type({{:., [], [Regex, :t]}, [], []})
    assert :ok = Validate.valid?(regex_t, ~r/a/, %{})

    assert {:error, {:validator, {ToolCall.Providers.Regex, :validate}, "a"}} =
             Validate.valid?(regex_t, "a", %{})
  end

  test "an optional field may be absent" do
    node = %Type{kind: :object, fields: [field(:a, int(), false)], additional: nil}
    assert :ok = Validate.valid?(node, %{}, %{})
  end

  test "an additional schema validates extra values" do
    node = %Type{kind: :object, fields: [], additional: int()}

    assert :ok = Validate.valid?(node, %{a: 1}, %{})
    assert {:error, {"a", {:expected_integer, "x"}}} = Validate.valid?(node, %{a: "x"}, %{})
  end

  test "a throwing validator is reported" do
    defmodule Throwing do
      def validate(_type, _value, _defs), do: throw(:nope)
    end

    node = %Type{kind: :string, validator: {Throwing, :validate}}
    assert {:error, {:validate_raised, :nope}} = Validate.valid?(node, "x", %{})
  end

  test "nonempty_binary derives its own source and rejects empty" do
    node = ToolCall.Typespec.to_type({:nonempty_binary, [], []})

    assert %Type{source: :nonempty_binary} = node
    assert {:error, _} = Validate.valid?(node, "", %{})
    assert :ok = Validate.valid?(node, "x", %{})
  end

  test "a non-atom/string map key does not raise" do
    closed = %Type{kind: :object, fields: [], additional: nil}

    assert {:error, {:unknown_keys, ["{:a}"]}} =
             Validate.valid?(closed, %{{:a} => 1}, %{})

    open = %Type{kind: :object, fields: [], additional: int()}

    assert {:error, {"{:a}", {:expected_integer, "x"}}} =
             Validate.valid?(open, %{{:a} => "x"}, %{})
  end

  test "improper lists are argument errors, not raises" do
    assert {:error, {:expected_array, [1 | 2]}} =
             Validate.valid?(%Type{kind: :array, items: int()}, [1 | 2], %{})

    assert {:error, {:expected_charlist, [97 | 98]}} =
             Validate.valid?(str(:charlist), [97 | 98], %{})
  end

  test "MapSet elements are validated" do
    assert :ok = Validate.valid?(mapset_t(), MapSet.new([1, 2]), %{})

    assert {:error, {:validator, {ToolCall.Providers.MapSet, :validate}, _value}} =
             Validate.valid?(mapset_t(), MapSet.new(["x"]), %{})
  end

  test "keyword elements are validated" do
    assert :ok = Validate.valid?(keyword_t(), [a: 1], %{})

    assert {:error, {:validator, {ToolCall.Providers.Stdlib, :validate_keyword}, _value}} =
             Validate.valid?(keyword_t(), [a: "x"], %{})

    any = type({:keyword, [], []})
    assert :ok = Validate.valid?(any, [a: "x"], %{})
  end

  test "a non-productive ref cycle raises instead of looping" do
    straight = %{
      "a" => %Type{kind: :ref, ref: "b"},
      "b" => %Type{kind: :ref, ref: "a"}
    }

    assert_raise ArgumentError, ~r/\$ref chain/, fn ->
      Validate.valid?(%Type{kind: :ref, ref: "a"}, 1, straight)
    end

    through_union = %{
      "a" => %Type{kind: :union, variants: [%Type{kind: :ref, ref: "b"}]},
      "b" => %Type{kind: :ref, ref: "a"}
    }

    assert_raise ArgumentError, ~r/\$ref chain/, fn ->
      Validate.valid?(%Type{kind: :ref, ref: "a"}, 1, through_union)
    end
  end
end
