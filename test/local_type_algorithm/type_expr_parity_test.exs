defmodule ToolCall.LocalTypeAlgorithm.TypeExprParityTest do
  use ExUnit.Case, async: true

  alias ToolCall.LocalTypeAlgorithm
  alias ToolCall.LocalTypeAlgorithm.{AstAdapter, TypeExprAdapter}
  alias ToolCall.TypeExpr.Compiler

  defp quoted(source),
    do: source |> Code.string_to_quoted!() |> Macro.prewalk(&Macro.expand(&1, __ENV__))

  defp ast_definitions do
    %{
      {:tree, 0} => {[], quoted("%{value: integer(), children: [tree()]}")},
      {:a, 0} => {[], quoted("b()")},
      {:b, 0} => {[], quoted("a()")},
      {:pair, 1} => {[{:x, [], nil}], quoted("%{left: x, right: x}")},
      {:rec, 1} => {[{:x, [], nil}], quoted("%{next: rec(x)}")},
      {:plain, 0} => {[], quoted("String.t()")}
    }
  end

  defp type_expr_definitions do
    Map.new(ast_definitions(), fn {key, {params, body}} ->
      {key, {params, ToolCall.TypeExpr.Typespec.from_ast(body)}}
    end)
  end

  setup do
    %{ast_defs: ast_definitions(), type_expr_defs: type_expr_definitions()}
  end

  test "cyclic detection matches between adapters", %{
    ast_defs: ast_defs,
    type_expr_defs: type_expr_defs
  } do
    assert LocalTypeAlgorithm.cyclic_keys(ast_defs, AstAdapter) ==
             LocalTypeAlgorithm.cyclic_keys(type_expr_defs, TypeExprAdapter)
  end

  test "both adapters produce the same instantiation keys, args, and names", %{
    ast_defs: ast_defs,
    type_expr_defs: type_expr_defs
  } do
    for source <- ["tree()", "a()", "rec(integer())", "pair(integer())", "plain()"] do
      ast = quoted(source)

      {_ast_out, ast_truncated, ast_insts} = LocalTypeAlgorithm.expand(ast, ast_defs, AstAdapter)

      type_expr = ToolCall.TypeExpr.Typespec.from_ast(ast)

      {_te_out, te_truncated, te_insts} =
        LocalTypeAlgorithm.expand(type_expr, type_expr_defs, TypeExprAdapter)

      assert ast_truncated == te_truncated
      assert Enum.map(ast_insts, & &1.key) == Enum.map(te_insts, & &1.key)

      assert Enum.map(ast_insts, & &1.name) == Enum.map(te_insts, & &1.name)
    end
  end

  test "both adapters rewrite instantiation refs to the same names", %{
    ast_defs: ast_defs,
    type_expr_defs: type_expr_defs
  } do
    ast = quoted("tree()")
    {ast_out, false, ast_insts} = LocalTypeAlgorithm.expand(ast, ast_defs, AstAdapter)

    ast_names =
      Map.new(ast_insts, fn inst -> {Enum.find_index(ast_insts, &(&1 == inst)), inst.name} end)

    assert AstAdapter.rewrite_refs(ast_out, ast_names) ==
             {{:., [], [:tool_call_ref, :ref]}, [], ["tree"]}

    type_expr = ToolCall.TypeExpr.Typespec.from_ast(ast)

    {te_out, false, te_insts} =
      LocalTypeAlgorithm.expand(type_expr, type_expr_defs, TypeExprAdapter)

    te_names =
      Map.new(te_insts, fn inst -> {Enum.find_index(te_insts, &(&1 == inst)), inst.name} end)

    assert TypeExprAdapter.rewrite_refs(te_out, te_names) == {:ref, "tree"}
  end

  test "TypeExpr expansion compiles to the same IR as the AST path", %{
    ast_defs: ast_defs,
    type_expr_defs: type_expr_defs
  } do
    providers = ToolCall.Typespec.builtin_providers()

    for source <- ["tree()", "rec(integer())", "pair(integer())", "plain()"] do
      ast = quoted(source)

      {ast_out, _truncated, ast_insts} = LocalTypeAlgorithm.expand(ast, ast_defs, AstAdapter)
      ast_names = Map.new(Enum.with_index(ast_insts), fn {inst, i} -> {i, inst.name} end)
      ast_out = AstAdapter.rewrite_refs(ast_out, ast_names)
      ast_ir = Compiler.to_type(ToolCall.TypeExpr.Typespec.from_ast(ast_out), providers)

      type_expr = ToolCall.TypeExpr.Typespec.from_ast(ast)

      {te_out, _truncated, te_insts} =
        LocalTypeAlgorithm.expand(type_expr, type_expr_defs, TypeExprAdapter)

      te_names = Map.new(Enum.with_index(te_insts), fn {inst, i} -> {i, inst.name} end)
      te_out = TypeExprAdapter.rewrite_refs(te_out, te_names)
      te_ir = Compiler.to_type(te_out, providers)

      assert ast_ir == te_ir
    end
  end
end
