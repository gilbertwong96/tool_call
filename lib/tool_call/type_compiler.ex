defmodule ToolCall.TypeCompiler do
  @moduledoc """
  Compiles a declaration's `ToolCall.TypeExpr` values into `ToolCall.IR.Type`.

  The compiler owns local-type expansion, recursive `$defs` hoisting, provider
  mapping, and result-type handling; the declaration source has already resolved
  aliases, current-module references, and `when` bindings. The builder remains
  responsible for docs, defaults, parameter names, and overrides.
  """

  alias ToolCall.IR.Type
  alias ToolCall.{LocalTypeAlgorithm, LocalTypes, TypeExpr}
  alias ToolCall.LocalTypeAlgorithm.TypeExprAdapter

  @type context :: map()

  @type t :: %{
          context: context(),
          definitions: map(),
          cyclic: MapSet.t(),
          defs: map(),
          registry: map()
        }

  @spec new(context()) :: t()
  def new(context) when is_map(context) do
    definitions = type_expr_definitions(context.definitions)

    %{
      context: context,
      definitions: definitions,
      cyclic: LocalTypeAlgorithm.cyclic_keys(definitions, TypeExprAdapter),
      defs: %{},
      registry: %{}
    }
  end

  @spec defs(t()) :: map()
  def defs(%{defs: defs}), do: defs

  @spec compile_param(t(), TypeExpr.t()) :: {Type.t(), boolean(), t()}
  def compile_param(state, type_expr) do
    compile(state, type_expr)
  end

  @spec compile_result(t(), TypeExpr.t()) :: {Type.t() | nil, boolean(), t()}
  def compile_result(state, {:unsupported, reason}) when reason in [:no_return, :none],
    do: {nil, false, state}

  def compile_result(state, return_expr) do
    {type, truncated?, state} = compile(state, return_expr)

    case type do
      %Type{kind: :unsupported, source: source} when source in [:no_return, :none] ->
        {nil, truncated?, state}

      _other ->
        {type, truncated?, state}
    end
  end

  defp compile(state, type_expr) do
    max_defs = max(LocalTypes.max_defs() - map_size(state.defs), 0)

    {expanded, truncated?, insts} =
      LocalTypeAlgorithm.expand(type_expr, state.definitions, TypeExprAdapter,
        cyclic: state.cyclic,
        max_defs: max_defs
      )

    names = for {inst, index} <- Enum.with_index(insts), into: %{}, do: {index, inst.name}
    expanded = TypeExprAdapter.rewrite_refs(expanded, names)

    defs =
      Enum.reduce(insts, state.defs, fn inst, defs ->
        body = TypeExprAdapter.rewrite_refs(inst.body, names)
        Map.put_new(defs, inst.name, TypeExpr.Compiler.to_type(body, state.context.providers))
      end)

    type = TypeExpr.Compiler.to_type(expanded, state.context.providers)
    {type, truncated?, %{state | defs: defs}}
  end

  # Local type definitions arrive as AST because they can be recursive and are
  # shared by every tool in the module. Converting once per tool keeps the
  # expansion and `$defs` naming in `TypeExpr` space.
  defp type_expr_definitions(definitions) when is_map(definitions) do
    Map.new(definitions, fn {key, {params, body}} ->
      {key, {params, TypeExpr.Typespec.from_ast(body)}}
    end)
  end
end
