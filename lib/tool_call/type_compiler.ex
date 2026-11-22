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

  @type prepared :: %{
          context: context(),
          definitions: map(),
          cyclic: MapSet.t()
        }

  @type t :: %{
          context: context(),
          definitions: map(),
          cyclic: MapSet.t(),
          defs: map()
        }

  @doc """
  Converts the module's local type definitions once.

  The result is shared by every tool in the module; `new/1` only resets the
  per-tool `$defs` budget.
  """
  @spec prepare(context()) :: prepared()
  def prepare(context) when is_map(context) do
    definitions = type_expr_definitions(context.definitions)

    %{
      context: context,
      definitions: definitions,
      cyclic: LocalTypeAlgorithm.cyclic_keys(definitions, TypeExprAdapter)
    }
  end

  @spec new(prepared()) :: t()
  def new(prepared) when is_map(prepared), do: Map.put(prepared, :defs, %{})

  @spec defs(t()) :: map()
  def defs(%{defs: defs}), do: defs

  @spec compile_param(t(), TypeExpr.t()) :: {Type.t(), boolean(), t()}
  def compile_param(state, type_expr) do
    compile(state, type_expr)
  end

  @spec compile_result(t(), TypeExpr.t()) :: {Type.t() | nil, boolean(), t()}
  def compile_result(state, {:unsupported, reason}) when reason in [:no_return, :none],
    do: {%Type{kind: :unsupported, source: reason}, false, state}

  def compile_result(state, return_expr), do: compile(state, return_expr)

  defp compile(state, type_expr) do
    case TypeExpr.validate(type_expr) do
      :ok ->
        compile_valid(state, type_expr)

      {:error, reason} ->
        {%Type{kind: :unsupported, source: {:invalid_type_expr, reason}}, false, state}
    end
  end

  defp compile_valid(state, type_expr) do
    max_defs = max(LocalTypes.max_defs() - map_size(state.defs), 0)

    {expanded, truncated?, insts} =
      LocalTypeAlgorithm.expand(type_expr, state.definitions, TypeExprAdapter,
        cyclic: state.cyclic,
        max_defs: max_defs
      )

    {names, defs} = assign_names(insts, state.defs)
    expanded = TypeExprAdapter.rewrite_refs(expanded, names)

    defs =
      insts
      |> Stream.with_index()
      |> Enum.reduce(defs, fn {inst, index}, defs ->
        body = TypeExprAdapter.rewrite_refs(inst.body, names)
        type = TypeExpr.Compiler.to_type(body, state.context.providers)
        Map.put(defs, Map.fetch!(names, index), type)
      end)

    type = TypeExpr.Compiler.to_type(expanded, state.context.providers)
    {type, truncated?, %{state | defs: defs}}
  end

  # Two instantiations can hash to the same readable name. Keeping the first and
  # dropping the second would leave a `$ref` pointing at another type's body, so
  # a collision takes a numeric suffix instead.
  @doc false
  @spec assign_names([map()], map()) :: {%{non_neg_integer() => String.t()}, map()}
  def assign_names(insts, defs) do
    {names, defs} =
      insts
      |> Stream.with_index()
      |> Enum.reduce({%{}, defs}, fn {inst, index}, {names, defs} ->
        name = unique_name(inst.name, defs)
        {Map.put(names, index, name), Map.put_new(defs, name, nil)}
      end)

    {names, Map.reject(defs, fn {_name, type} -> is_nil(type) end)}
  end

  defp unique_name(name, defs), do: unique_name(name, defs, 1)

  defp unique_name(base, defs, counter) do
    candidate = if counter == 1, do: base, else: "#{base}_#{counter}"

    if Map.has_key?(defs, candidate),
      do: unique_name(base, defs, counter + 1),
      else: candidate
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
