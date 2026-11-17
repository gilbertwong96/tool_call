defmodule ToolCall.TypeCompiler do
  @moduledoc """
  Compiles a source-neutral declaration's type ASTs into `ToolCall.IR.Type` values.

  The compiler owns alias expansion, local-type expansion, recursive `$defs`
  hoisting, provider mapping, and result-type handling. the builder
  remains responsible for docs, defaults, parameter names, and overrides.
  """

  alias ToolCall.IR.Type
  alias ToolCall.{LocalTypes, TypeAst, TypeExpr}

  @type context :: map()

  @type t :: %{context: context(), defs: map(), registry: map()}

  @spec new(context()) :: t()
  def new(context) when is_map(context) do
    %{context: context, defs: %{}, registry: %{}}
  end

  @spec defs(t()) :: map()
  def defs(%{defs: defs}), do: defs

  @spec compile_param(t(), term(), %{atom() => term()}) ::
          {Type.t(), term(), boolean(), t()}
  def compile_param(state, type_ast, bindings) do
    compile(state, type_ast, bindings)
  end

  @spec compile_result(t(), term(), %{atom() => term()}) ::
          {Type.t() | nil, boolean(), t()}
  def compile_result(state, {:no_return, _meta, []}, _bindings), do: {nil, false, state}
  def compile_result(state, {:none, _meta, []}, _bindings), do: {nil, false, state}

  def compile_result(state, return_ast, bindings) do
    {type, _source_ast, truncated?, state} = compile(state, return_ast, bindings)

    case type do
      %Type{kind: :unsupported, source: source} when source in [:no_return, :none] ->
        {nil, truncated?, state}

      _other ->
        {type, truncated?, state}
    end
  end

  defp compile(state, type_ast, bindings) do
    context = state.context
    source_ast = TypeAst.normalize(type_ast, bindings, context.env)
    max_defs = max(LocalTypes.max_defs() - map_size(state.defs), 0)

    {expanded_ast, truncated?, insts} =
      LocalTypes.expand(source_ast, context.definitions,
        cyclic: context.cyclic,
        max_defs: max_defs
      )

    {expanded_ast, state} = hoist_instantiations(expanded_ast, insts, state)
    expanded_ast = TypeAst.normalize(expanded_ast, context.env)
    type = TypeExpr.Compiler.to_type(TypeExpr.Typespec.from_ast(expanded_ast), context.providers)

    {type, source_ast, truncated?, state}
  end

  defp hoist_instantiations(type_ast, insts, state) do
    {refs, registry} =
      Enum.map_reduce(insts, state.registry, fn inst, registry ->
        {ref_name, registry} = assign_name(inst, registry)
        {ref_name, registry}
      end)

    names = refs |> Enum.with_index() |> Map.new(fn {ref, index} -> {index, ref} end)

    defs =
      insts
      |> Enum.zip(refs)
      |> Enum.reduce(state.defs, fn {inst, ref_name}, defs ->
        body = LocalTypes.rewrite_refs(inst.body, names)

        type =
          TypeExpr.Compiler.to_type(TypeExpr.Typespec.from_ast(body), state.context.providers)

        Map.put_new(defs, ref_name, type)
      end)

    {LocalTypes.rewrite_refs(type_ast, names), %{state | defs: defs, registry: registry}}
  end

  defp assign_name(%{key: key, args: args}, registry) do
    instantiation = {key, args}

    case Map.fetch(registry, instantiation) do
      {:ok, ref_name} ->
        {ref_name, registry}

      :error ->
        ref_name = unique_ref_name(LocalTypes.name(key, args), registry, 1)
        {ref_name, Map.put(registry, instantiation, ref_name)}
    end
  end

  defp unique_ref_name(base, registry, counter) do
    candidate = if counter == 1, do: base, else: "#{base}_#{counter}"

    if Enum.any?(registry, fn {_instantiation, name} -> name == candidate end),
      do: unique_ref_name(base, registry, counter + 1),
      else: candidate
  end
end
