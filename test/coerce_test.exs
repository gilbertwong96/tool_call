defmodule ToolCall.CoerceTest.Transform do
  @moduledoc false

  def raising(_value), do: raise("boom")
  def throwing(_value), do: throw(:boom)
  def exiting(_value), do: exit(:boom)
  def wrapping(value), do: {:ok, {:wrapped, value}}
end

defmodule ToolCall.CoerceTest do
  use ExUnit.Case, async: true

  alias ToolCall.Coerce
  alias ToolCall.CoerceTest.Transform
  alias ToolCall.IR.{Field, Param, Type}

  defp integer(opts \\ []) do
    struct(%Type{
      kind: :integer,
      minimum: Keyword.get(opts, :min),
      maximum: Keyword.get(opts, :max)
    })
  end

  defp keyword(additional), do: ToolCall.Providers.Stdlib.keyword_type(additional)

  defp calendar(module), do: ToolCall.Typespec.to_type({{:., [], [module, :t]}, [], []})

  defp float, do: %Type{kind: :float}
  defp number, do: %Type{kind: :number}

  describe "integers" do
    test "accepts integers within bounds" do
      assert {:ok, 5} = Coerce.coerce(integer(min: 1), 5)
    end

    test "rejects integers outside bounds" do
      assert {:error, {:below_minimum, 0, 1}} = Coerce.coerce(integer(min: 1), 0)
    end

    test "truncates integral floats, because JSON Schema calls 1.0 an integer" do
      assert {:ok, 1} = Coerce.coerce(integer(), 1.0)
    end

    test "rejects fractional floats" do
      assert {:error, {:expected_integer, 1.5}} = Coerce.coerce(integer(), 1.5)
    end

    test "rejects numeric strings without a string wire format" do
      assert {:error, _} = Coerce.coerce(integer(), "42")
      assert {:ok, 42} = Coerce.coerce(integer(), "42", :string_integer)
    end

    test "accepts the number form as a convenience" do
      assert {:ok, 42} = Coerce.coerce(integer(), 42, :string_integer)
    end

    test "carries arbitrary precision when sent as a string" do
      big = Integer.pow(2, 70)
      assert {:ok, ^big} = Coerce.coerce(integer(), Integer.to_string(big), :string_integer)
      assert {:ok, ^big} = Coerce.coerce(integer(), big)
    end
  end

  describe "floats" do
    test "widens integers" do
      assert {:ok, 2.0} = Coerce.coerce(float(), 2)
      assert is_float(elem(Coerce.coerce(float(), 2), 1))
    end

    test "leaves floats alone" do
      assert {:ok, 2.5} = Coerce.coerce(float(), 2.5)
    end

    test "rejects a non-number" do
      assert {:error, {:expected_float, "x"}} = Coerce.coerce(float(), "x")
    end

    test "rejects an integer too large to widen" do
      huge = Integer.pow(10, 400)
      assert {:error, {:expected_float, ^huge}} = Coerce.coerce(float(), huge)
    end

    test "enforces float bounds" do
      type = %Type{kind: :float, minimum: 1.5, maximum: 2.5}

      assert {:ok, 2.0} = Coerce.coerce(type, 2)
      assert {:error, {:below_minimum, 1.0, 1.5}} = Coerce.coerce(type, 1.0)
      assert {:error, {:above_maximum, 3.0, 2.5}} = Coerce.coerce(type, 3.0)
    end
  end

  describe "numbers" do
    test "accepts both" do
      assert {:ok, 2} = Coerce.coerce(number(), 2)
      assert {:ok, 2.5} = Coerce.coerce(number(), 2.5)
    end

    test "rejects a non-number" do
      assert {:error, {:expected_number, "x"}} = Coerce.coerce(number(), "x")
    end

    test "enforces number bounds" do
      type = %Type{kind: :number, minimum: 1, maximum: 3}

      assert {:ok, 2} = Coerce.coerce(type, 2)
      assert {:error, {:below_minimum, 0.5, 1}} = Coerce.coerce(type, 0.5)
      assert {:error, {:above_maximum, 4, 3}} = Coerce.coerce(type, 4)
    end
  end

  describe "nullable" do
    test "accepts nil only when the type allows it" do
      assert {:ok, nil} = Coerce.coerce(%{integer() | nullable: true}, nil)
      assert {:error, _} = Coerce.coerce(integer(), nil)
    end
  end

  describe "enums" do
    test "maps JSON strings back to atoms" do
      type = %Type{kind: :enum, values: [:red, :green]}
      assert {:ok, :red} = Coerce.coerce(type, "red")
      assert {:error, _} = Coerce.coerce(type, "blue")
    end

    test "accepts the atom form directly" do
      type = %Type{kind: :enum, values: [:red]}
      assert {:ok, :red} = Coerce.coerce(type, :red)
    end

    test "keeps non-atom enums as-is" do
      type = %Type{kind: :enum, values: [1, 2]}
      assert {:ok, 1} = Coerce.coerce(type, 1)
    end

    test "accepts an integral float, like integer()" do
      type = %Type{kind: :enum, values: [1, 2]}
      assert {:ok, 1} = Coerce.coerce(type, 1.0)
      assert {:error, _} = Coerce.coerce(type, 1.5)
    end

    test "boolean enums keep the singleton" do
      type = %Type{kind: :enum, values: [true]}
      assert {:ok, true} = Coerce.coerce(type, true)
      assert {:error, {:invalid_enum, false, [true]}} = Coerce.coerce(type, false)
    end

    test "an empty enum accepts strings, matching its schema" do
      assert {:ok, "x"} = Coerce.coerce(%Type{kind: :enum, values: []}, "x")
      assert {:ok, "x"} = Coerce.coerce(%Type{kind: :enum, values: nil}, "x")
      assert {:error, {:invalid_enum, 1, []}} = Coerce.coerce(%Type{kind: :enum, values: []}, 1)
    end

    test "rejects invalid utf-8 before matching an enum" do
      assert {:error, {:invalid_utf8, <<255>>}} =
               Coerce.coerce(%Type{kind: :enum, values: [:a]}, <<255>>)
    end
  end

  describe "accepted nil domains" do
    test "recognises domains that accept nil" do
      enum_with_nil = %Type{kind: :enum, values: [nil, :a]}

      assert Coerce.accepts_nil?(%Type{kind: :integer, nullable: true})
      assert Coerce.accepts_nil?(%Type{kind: :null})
      assert Coerce.accepts_nil?(%Type{kind: :any})
      assert Coerce.accepts_nil?(enum_with_nil)
      assert Coerce.accepts_nil?(%Type{kind: :union, variants: [enum_with_nil]})
      refute Coerce.accepts_nil?(%Type{kind: :integer})
      refute Coerce.accepts_nil?(%Type{kind: :enum, values: [:a]})
      refute Coerce.accepts_nil?(%Type{kind: :union, variants: [%Type{kind: :integer}]})
    end
  end

  describe "objects" do
    test "treats an explicit null for an optional field as absent" do
      type = %Type{
        kind: :object,
        fields: [
          %Field{name: "a", key: :a, type: %Type{kind: :string}, required: false},
          %Field{name: "b", key: :b, type: %Type{kind: :integer}}
        ]
      }

      assert {:ok, %{b: 1}} = Coerce.coerce(type, %{"a" => nil, "b" => 1})
      assert {:error, _} = Coerce.coerce(type, %{"a" => nil, "b" => nil})
    end

    test "keeps explicit null for an optional nullable field" do
      type = %Type{
        kind: :object,
        fields: [
          %Field{
            name: "a",
            key: :a,
            type: %Type{kind: :integer, nullable: true},
            required: false
          },
          %Field{name: "b", key: :b, type: %Type{kind: :integer}}
        ]
      }

      assert {:ok, %{a: nil, b: 1}} = Coerce.coerce(type, %{"a" => nil, "b" => 1})
    end

    test "coerces known fields" do
      type = %Type{
        kind: :object,
        fields: [%Field{name: "n", key: :n, type: integer(), required: true}]
      }

      assert {:ok, %{n: 3}} = Coerce.coerce(type, %{"n" => 3.0})
    end

    test "falls back to the field name when the key is nil" do
      type = %Type{
        kind: :object,
        fields: [%Field{name: "n", key: nil, type: integer(), required: true}]
      }

      assert {:ok, %{"n" => 1}} = Coerce.coerce(type, %{"n" => 1})
    end

    test "rejects unknown keys when additionalProperties is false" do
      type = %Type{kind: :object, fields: []}
      assert {:error, {:unknown_keys, ["x"]}} = Coerce.coerce(type, %{"x" => 1})
    end

    test "coerces extra values when the map is open" do
      type = %Type{kind: :object, fields: [], additional: integer()}
      assert {:ok, %{"a" => 1, "b" => 2}} = Coerce.coerce(type, %{"a" => 1.0, "b" => 2})
    end

    test "restores atom keys in nested objects" do
      type = %Type{
        kind: :object,
        fields: [
          %Field{
            name: "point",
            key: :point,
            type: %Type{
              kind: :object,
              fields: [
                %Field{name: "x", key: :x, type: integer()},
                %Field{name: "y", key: :y, type: integer()}
              ]
            }
          }
        ]
      }

      assert {:ok, %{point: %{x: 1, y: 2}}} =
               Coerce.coerce(type, %{"point" => %{"x" => 1.0, "y" => 2}})
    end

    test "turns a keyword object into a keyword list" do
      type = keyword(%Type{kind: :string})
      assert {:ok, [a: "x"]} = Coerce.coerce(type, %{"a" => "x"})
    end

    test "accepts atom keys, which the value domain uses" do
      type = keyword(integer())
      assert {:ok, [a: 1]} = Coerce.coerce(type, %{a: 1})
    end

    test "rejects keyword keys that are not existing atoms" do
      type = keyword(%Type{kind: :string})

      assert {:error, {:unknown_atom, "definitely_not_an_existing_atom"}} =
               Coerce.coerce(type, %{"definitely_not_an_existing_atom" => "x"})
    end

    test "rejects invalid utf-8 keyword keys" do
      type = keyword(%Type{kind: :string})
      assert {:error, {:invalid_utf8, <<255>>}} = Coerce.coerce(type, %{<<255>> => "x"})
    end

    test "reports which keyword value failed" do
      type = keyword(integer())
      assert {:error, {"a", {:expected_integer, "x"}}} = Coerce.coerce(type, %{"a" => "x"})
    end

    test "rejects a key JSON could not produce" do
      type = keyword(integer())
      assert {:error, {:invalid_key, 1}} = Coerce.coerce(type, %{1 => 1})
    end
  end

  describe "scalars" do
    test "strings" do
      assert {:ok, "a"} = Coerce.coerce(%Type{kind: :string}, "a")
      assert {:error, {:expected_string, 1}} = Coerce.coerce(%Type{kind: :string}, 1)
    end

    test "nonempty strings reject the empty value" do
      for source <- [:binary, :string] do
        type = %Type{kind: :string, source: source, pattern: "^[\\s\\S]+$"}
        type = ToolCall.Typespec.validate_type!(type)

        assert {:ok, "a"} = Coerce.coerce(type, "a")
        assert {:error, {:pattern_mismatch, _, ""}} = Coerce.coerce(type, "")
      end
    end

    test "rejects invalid utf-8 for every string wire shape" do
      invalid = <<255>>

      for type <- [
            %Type{kind: :string},
            %Type{kind: :string, source: :binary},
            %Type{kind: :string, source: :bitstring},
            %Type{kind: :string, source: :charlist},
            %Type{kind: :string, source: :char},
            %Type{kind: :string, pattern: "^.$"},
            %Type{kind: :string, source: {String, :t}}
          ] do
        assert {:error, {:invalid_utf8, ^invalid}} = Coerce.coerce(type, invalid)
      end
    end

    test "parses calendar types from ISO 8601" do
      assert {:ok, ~D[2024-01-31]} =
               Coerce.coerce(calendar(Date), "2024-01-31")

      assert {:error, {:invalid_date, "31/01/2024"}} =
               Coerce.coerce(calendar(Date), "31/01/2024")

      assert {:ok, ~T[10:30:00]} =
               Coerce.coerce(calendar(Time), "10:30:00")

      assert {:ok, ~N[2024-01-31 10:30:00]} =
               Coerce.coerce(
                 calendar(NaiveDateTime),
                 "2024-01-31T10:30:00"
               )

      assert {:ok, %DateTime{hour: 10}} =
               Coerce.coerce(calendar(DateTime), "2024-01-31T10:30:00Z")

      assert {:error, {:invalid_datetime, "nope"}} =
               Coerce.coerce(calendar(DateTime), "nope")

      assert {:error, {:invalid_time, "25:00:00"}} =
               Coerce.coerce(calendar(Time), "25:00:00")

      assert {:error, {:invalid_naive_datetime, "nope"}} =
               Coerce.coerce(calendar(NaiveDateTime), "nope")
    end

    test "charlists come back as charlists" do
      assert {:ok, ~c"abc"} = Coerce.coerce(%Type{kind: :string, source: :charlist}, "abc")
    end

    test "rejects invalid utf-8 charlists instead of raising" do
      assert {:error, {:invalid_utf8, <<255>>}} =
               Coerce.coerce(%Type{kind: :string, source: :charlist}, <<255>>)
    end

    test "requires a compiled pattern for hand-built types" do
      assert_raise ArgumentError, ~r/no compiled pattern_regex/, fn ->
        Coerce.coerce(%Type{kind: :string, pattern: "^x$"}, "x")
      end
    end

    test "enforces the rendered pattern" do
      type = ToolCall.Typespec.validate_type!(%Type{kind: :string, pattern: "^.$"})

      assert {:ok, "a"} = Coerce.coerce(type, "a")
      assert {:error, {:pattern_mismatch, "^.$", "ab"}} = Coerce.coerce(type, "ab")
    end

    test "uses the compiled pattern when present" do
      type = ToolCall.Typespec.to_type({:char, [], []})

      assert %Type{pattern_regex: %Regex{}} = type
      assert {:ok, ?a} = Coerce.coerce(type, "a")
      assert {:error, {:pattern_mismatch, "^[\\s\\S]$", "ab"}} = Coerce.coerce(type, "ab")
    end

    test "char returns the codepoint, including newline and unicode" do
      type = ToolCall.Typespec.to_type({:char, [], []})

      assert {:ok, ?a} = Coerce.coerce(type, "a")
      assert {:ok, ?\n} = Coerce.coerce(type, "\n")
      assert {:ok, ?é} = Coerce.coerce(type, "é")
      assert {:error, {:pattern_mismatch, _, "ab"}} = Coerce.coerce(type, "ab")
      assert {:error, {:invalid_utf8, <<255>>}} = Coerce.coerce(type, <<255>>)
    end

    test "booleans" do
      assert {:ok, true} = Coerce.coerce(%Type{kind: :boolean}, true)
      assert {:error, {:expected_boolean, "true"}} = Coerce.coerce(%Type{kind: :boolean}, "true")
    end

    test "atoms map strings back to existing atoms only" do
      assert {:ok, :ok} = Coerce.coerce(%Type{kind: :atom}, "ok")
      assert {:ok, :ok} = Coerce.coerce(%Type{kind: :atom}, :ok)

      assert {:error, {:unknown_atom, "not_an_existing_atom"}} =
               Coerce.coerce(%Type{kind: :atom}, "not_an_existing_atom")

      assert {:error, {:expected_atom, 1}} = Coerce.coerce(%Type{kind: :atom}, 1)

      # The wire type is a string; null and booleans are only valid when the
      # spec makes them part of the domain.
      assert {:error, {:expected_atom, nil}} = Coerce.coerce(%Type{kind: :atom}, nil)
      assert {:error, {:expected_atom, true}} = Coerce.coerce(%Type{kind: :atom}, true)

      assert {:error, {:expected_atom, "true"}} = Coerce.coerce(%Type{kind: :atom}, "true")
      assert {:error, {:expected_atom, "false"}} = Coerce.coerce(%Type{kind: :atom}, "false")
      assert {:error, {:expected_atom, "nil"}} = Coerce.coerce(%Type{kind: :atom}, "nil")
      assert {:error, {:invalid_utf8, <<255>>}} = Coerce.coerce(%Type{kind: :atom}, <<255>>)
      assert {:ok, nil} = Coerce.coerce(%Type{kind: :atom, nullable: true}, nil)
    end

    test "null" do
      assert {:ok, nil} = Coerce.coerce(%Type{kind: :null}, nil)
      assert {:error, {:expected_null, 1}} = Coerce.coerce(%Type{kind: :null}, 1)
    end

    test "any passes the value through untouched" do
      assert {:ok, %{a: 1}} = Coerce.coerce(%Type{kind: :any}, %{a: 1})
    end

    test "unsupported domains are refused" do
      assert {:error, :unsupported_type} = Coerce.coerce(%Type{kind: :unsupported}, self())
    end
  end

  describe "arrays" do
    test "accepts an empty list" do
      type = %Type{kind: :array, items: %Type{kind: :integer}}
      assert {:ok, []} = Coerce.coerce(type, [])
    end

    test "coerce every item" do
      type = %Type{kind: :array, items: %Type{kind: :integer}}
      assert {:ok, [1, 2]} = Coerce.coerce(type, [1.0, 2])
      assert {:error, {1, {:expected_integer, 2.5}}} = Coerce.coerce(type, [1, 2.5])
    end

    test "enforce minItems" do
      type = %Type{kind: :array, items: %Type{kind: :integer}, minimum: 2}
      assert {:error, {:too_few_items, 1, 2}} = Coerce.coerce(type, [1])
    end

    test "enforce maxItems" do
      type = %Type{kind: :array, items: %Type{kind: :integer}, maximum: 2}
      assert {:ok, [1, 2]} = Coerce.coerce(type, [1, 2])
      assert {:error, {:too_many_items, 3, 2}} = Coerce.coerce(type, [1, 2, 3])
    end

    test "reject a non-list" do
      assert {:error, {:expected_array, "x"}} = Coerce.coerce(%Type{kind: :array}, "x")
    end
  end

  describe "tuples" do
    test "check the size and coerce each position" do
      type = %Type{kind: :tuple, items: [%Type{kind: :integer}, %Type{kind: :string}]}

      assert {:ok, {1, "a"}} = Coerce.coerce(type, [1.0, "a"])
      assert {:error, {:wrong_tuple_size, 1, 2}} = Coerce.coerce(type, [1])
      assert {:error, {:expected_array, %{}}} = Coerce.coerce(type, %{})
      assert {:error, {0, {:expected_integer, "a"}}} = Coerce.coerce(type, ["a", "b"])
    end

    test "an unconstrained tuple accepts any arity" do
      type = %Type{kind: :tuple, items: nil}

      assert {:ok, {1, "a"}} = Coerce.coerce(type, [1, "a"])
      assert {:ok, {}} = Coerce.coerce(type, [])
    end
  end

  describe "union variants" do
    test "a hand-built union without variants reports no match" do
      assert {:error, {:no_variant_matched, 1}} =
               Coerce.coerce(%Type{kind: :union, variants: nil}, 1)
    end

    test "take the first match and report when none does" do
      type = %Type{kind: :union, variants: [%Type{kind: :integer}, %Type{kind: :string}]}

      assert {:ok, 1} = Coerce.coerce(type, 1)
      assert {:ok, "a"} = Coerce.coerce(type, "a")
      assert {:error, {:no_variant_matched, :x}} = Coerce.coerce(type, :x)
    end
  end

  describe "objects without a schema" do
    test "reject a non-map" do
      assert {:error, {:expected_object, []}} = Coerce.coerce(%Type{kind: :object}, [])
    end

    test "pass extra values through when additionalProperties is unconstrained" do
      type = %Type{kind: :object, fields: [], additional: %Type{kind: :any}}
      assert {:ok, %{"a" => %{b: 1}}} = Coerce.coerce(type, %{"a" => %{b: 1}})
    end

    test "reject a non-integer key value when additionalProperties is typed" do
      type = %Type{kind: :object, fields: [], additional: integer()}
      assert {:error, {"a", {:expected_integer, "x"}}} = Coerce.coerce(type, %{"a" => "x"})
    end

    test "report a missing required field" do
      type = %Type{kind: :object, fields: [%Field{name: "n", type: integer(), required: true}]}
      assert {:error, {:missing, "n"}} = Coerce.coerce(type, %{})
    end

    test "allow a missing optional field" do
      type = %Type{kind: :object, fields: [%Field{name: "n", type: integer(), required: false}]}
      assert {:ok, %{}} = Coerce.coerce(type, %{})
    end

    test "carry the field name into nested errors" do
      type = %Type{kind: :object, fields: [%Field{name: "n", type: integer(), required: true}]}
      assert {:error, {"n", {:expected_integer, "x"}}} = Coerce.coerce(type, %{"n" => "x"})
    end
  end

  describe "containers" do
    test "coerce a list of tuples element-wise" do
      type = %Type{
        kind: :array,
        items: %Type{kind: :tuple, items: [%Type{kind: :string}, %Type{kind: :integer}]}
      }

      assert {:ok, [{"a", 1}, {"b", 2}]} = Coerce.coerce(type, [["a", 1.0], ["b", 2]])
    end

    test "report the array index and the tuple position" do
      type = %Type{
        kind: :array,
        items: %Type{kind: :tuple, items: [%Type{kind: :string}, %Type{kind: :integer}]}
      }

      assert {:error, {0, {1, {:expected_integer, "x"}}}} =
               Coerce.coerce(type, [["a", "x"]])
    end
  end

  describe "wire strings" do
    test "reject values that are not decimal integers" do
      assert {:error, {:expected_integer_string, "1.5"}} =
               Coerce.coerce(integer(), "1.5", :string_integer)

      assert {:error, {:expected_integer_string, nil}} =
               Coerce.coerce(integer(), nil, :string_integer)
    end

    test "rejects a leading plus sign, matching the schema pattern" do
      assert {:error, {:expected_integer_string, "+1"}} =
               Coerce.coerce(integer(), "+1", :string_integer)
    end

    test "rejects invalid utf-8 before parsing an integer string" do
      assert {:error, {:invalid_utf8, <<255>>}} =
               Coerce.coerce(integer(), <<255>>, :string_integer)
    end

    test "enforce bounds after parsing" do
      assert {:error, {:below_minimum, 0, 1}} =
               Coerce.coerce(integer(min: 1), "0", :string_integer)
    end

    test "accept nil when the domain is nullable" do
      assert {:ok, nil} = Coerce.coerce(%{integer() | nullable: true}, nil, :string_integer)
    end

    test "still accept a JSON integer" do
      assert {:ok, 5} = Coerce.coerce(integer(), 5, :string_integer)
    end
  end

  describe "transforms" do
    test "wraps raised, thrown and exited transform exceptions" do
      type = fn fun -> %Type{kind: :string, transform: {Transform, fun}} end

      assert {:error, {:invalid_transform, {:raised, "boom"}}} =
               Coerce.coerce(type.(:raising), "x")

      assert {:error, {:invalid_transform, {:thrown, :boom}}} =
               Coerce.coerce(type.(:throwing), "x")

      assert {:error, {:invalid_transform, {:exited, :boom}}} =
               Coerce.coerce(type.(:exiting), "x")
    end

    test "rejects a malformed transform" do
      assert {:error, {:invalid_transform, :bad}} =
               Coerce.coerce(%Type{kind: :string, transform: :bad}, "x")
    end

    test "applies a transform on any-typed additional values" do
      type = %Type{
        kind: :object,
        fields: [],
        additional: %Type{kind: :any, transform: {Transform, :wrapping}}
      }

      assert {:ok, %{"x" => {:wrapped, "value"}}} =
               Coerce.coerce(type, %{"x" => "value"})
    end
  end

  describe "param/2" do
    test "prefixes errors with the parameter name" do
      param = %Param{name: "user_id", type: integer(min: 1), wire: :number}
      assert {:error, {"user_id", {:below_minimum, 0, 1}}} = Coerce.param(param, 0)
    end
  end
end
