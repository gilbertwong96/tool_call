defmodule ToolCall.TypeExpr.ProjectionTest do
  use ExUnit.Case, async: true

  alias ToolCall.IR.Type
  alias ToolCall.TypeExpr.{Compiler, Projection}

  test "any and none are identities" do
    assert Projection.intersect(:any, {:primitive, :integer}) == {:ok, {:primitive, :integer}}
    assert Projection.intersect({:primitive, :integer}, :any) == {:ok, {:primitive, :integer}}
    assert Projection.intersect(:none, {:primitive, :integer}) == {:ok, :none}
    assert Projection.intersect({:primitive, :integer}, :none) == {:ok, :none}
  end

  test "integer ranges intersect to their overlap" do
    assert Projection.intersect({:integer_range, 1, 10}, {:integer_range, 5, 20}) ==
             {:ok, {:integer_range, 5, 10}}

    assert Projection.intersect({:integer_range, 1, 10}, {:integer_range, 20, 30}) ==
             {:ok, :none}

    assert Projection.intersect({:primitive, :integer}, {:integer_range, 5, 20}) ==
             {:ok, {:integer_range, 5, 20}}
  end

  test "literals and enums intersect exactly" do
    assert Projection.intersect({:literal, 5}, {:integer_range, 1, 10}) == {:ok, {:literal, 5}}
    assert Projection.intersect({:literal, 50}, {:integer_range, 1, 10}) == {:ok, :none}
    assert Projection.intersect({:literal, :a}, {:enum, [:a, :b]}) == {:ok, {:literal, :a}}
    assert Projection.intersect({:literal, :c}, {:enum, [:a, :b]}) == {:ok, :none}
  end

  test "disjoint literals intersect to the empty type" do
    assert Projection.intersect({:literal, 1}, {:literal, 2}) == {:ok, :none}
    assert Projection.intersect({:literal, :a}, {:primitive, :string}) == {:ok, :none}
    assert Projection.intersect({:literal, :a}, {:primitive, :atom}) == {:ok, {:literal, :a}}
  end

  test "a closed object stays closed when intersected with an open one" do
    closed = {:map, [{:a, {:primitive, :integer}, true}], nil}
    open = {:map, [], :any}

    assert Projection.intersect(closed, open) ==
             {:ok, {:map, [{:a, {:primitive, :integer}, true}], nil}}
  end

  test "maps merge their fields" do
    left = {:map, [{:a, {:primitive, :integer}, true}], nil}
    right = {:map, [{:b, {:primitive, :string}, false}], nil}

    assert Projection.intersect(left, right) ==
             {:ok,
              {:map, [{:a, {:primitive, :integer}, true}, {:b, {:primitive, :string}, false}],
               nil}}
  end

  test "an impossible field intersection is reported, not widened" do
    left = {:map, [{:a, {:primitive, :integer}, true}], nil}
    right = {:map, [{:a, {:primitive, :string}, true}], nil}

    assert Projection.intersect(left, right) == :error
  end

  test "enums intersect to their common values" do
    assert Projection.intersect({:enum, [:a, :b]}, {:enum, [:b, :c]}) == {:ok, {:literal, :b}}
    assert Projection.intersect({:enum, [:a]}, {:enum, [:c]}) == {:ok, :none}
  end

  test "subtracting a union subtracts each variant and stays flat" do
    assert Projection.subtract(
             {:integer_range, 1, 10},
             {:union, [{:integer_range, 2, 3}, {:integer_range, 8, 9}]}
           ) ==
             {:ok,
              {:union,
               [
                 {:integer_range, 1, 1},
                 {:integer_range, 4, 7},
                 {:integer_range, 10, 10}
               ]}}
  end

  test "a negation operand becomes a difference" do
    assert Projection.intersect({:enum, [:a, :b, :c]}, {:negation, {:literal, :b}}) ==
             {:ok, {:enum, [:a, :c]}}
  end

  test "subtracting a range splits the remaining integers" do
    assert Projection.subtract({:integer_range, 1, 10}, {:integer_range, 4, 6}) ==
             {:ok, {:union, [{:integer_range, 1, 3}, {:integer_range, 7, 10}]}}
  end

  test "subtracting an open range keeps the remaining side" do
    assert Projection.subtract({:primitive, :integer}, {:integer_range, 4, nil}) ==
             {:ok, {:integer_range, nil, 3}}
  end

  test "tuples intersect position by position" do
    left = {:tuple, [{:primitive, :integer}, {:primitive, :string}]}
    right = {:tuple, [{:integer_range, 1, 5}, {:primitive, :string}]}

    assert Projection.intersect(left, right) ==
             {:ok, {:tuple, [{:integer_range, 1, 5}, {:primitive, :string}]}}

    assert Projection.intersect(left, {:tuple, [{:primitive, :integer}]}) == {:ok, :none}
  end

  test "an unconstrained tuple is the identity for a fixed tuple" do
    fixed = {:tuple, [{:primitive, :integer}]}

    assert Projection.intersect({:tuple, nil}, fixed) == {:ok, fixed}
    assert Projection.intersect(fixed, {:tuple, nil}) == {:ok, fixed}
  end

  test "identical refs and remotes intersect to themselves" do
    assert Projection.intersect({:ref, "tree"}, {:ref, "tree"}) == {:ok, {:ref, "tree"}}

    assert Projection.intersect(
             {:remote, Date, :t, []},
             {:remote, Date, :t, []}
           ) == {:ok, {:remote, Date, :t, []}}

    assert Projection.intersect({:ref, "tree"}, {:ref, "other"}) == :error
  end

  test "string constraints narrow, conflicting ones do not" do
    assert Projection.intersect({:string, %{format: "date"}}, {:string, %{}}) ==
             {:ok, {:string, %{format: "date"}}}

    assert Projection.intersect({:string, %{format: "date"}}, {:string, %{format: "time"}}) ==
             :error
  end

  test "unsupported differences report an error" do
    assert Projection.subtract({:primitive, :atom}, {:literal, :x}) == :error
    assert Projection.intersect({:primitive, :atom}, {:primitive, :string}) == :error
  end

  test "the compiler lowers an exact intersection" do
    type = {:intersection, [{:integer_range, 1, 10}, {:integer_range, 5, 20}]}
    assert %Type{kind: :integer, minimum: 5, maximum: 10} = Compiler.to_type(type, [])
  end

  test "the compiler does not silently widen an inexact intersection" do
    type = {:intersection, [{:primitive, :atom}, {:primitive, :string}]}

    assert %Type{kind: :unsupported, source: :intersection} = Compiler.to_type(type, [])
  end
end
