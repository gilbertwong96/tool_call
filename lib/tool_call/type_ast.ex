defmodule ToolCall.TypeAst do
  @moduledoc """
  Shared normalization for typespec ASTs before they reach `ToolCall.TypeCompiler`.

  Normalization substitutes `when` variables, expands aliases, and turns
  `__MODULE__.t()` references into local calls so local-type expansion can see
  them.
  """

  @doc false
  @spec normalize(term(), Macro.Env.t()) :: term()
  def normalize(ast, %Macro.Env{} = env), do: normalize(ast, %{}, env)

  @doc false
  @spec normalize(term(), %{atom() => term()}, Macro.Env.t()) :: term()
  def normalize(ast, bindings, %Macro.Env{} = env) do
    ast
    |> substitute_vars(bindings)
    |> expand_aliases(env)
    |> localize_module_types(env.module)
  end

  @doc false
  @spec int_literal(term()) :: {:ok, integer()} | :error
  def int_literal(value) when is_integer(value), do: {:ok, value}
  def int_literal({:-, _, [value]}) when is_integer(value), do: {:ok, -value}
  def int_literal(_other), do: :error

  @doc false
  @spec substitute_vars(term(), %{atom() => term()}) :: term()
  def substitute_vars({name, _meta, context} = node, bindings)
      when is_atom(name) and is_atom(context) do
    Map.get(bindings, name, node)
  end

  def substitute_vars({left, right}, bindings),
    do: {substitute_vars(left, bindings), substitute_vars(right, bindings)}

  def substitute_vars(list, bindings) when is_list(list),
    do: Enum.map(list, &substitute_vars(&1, bindings))

  def substitute_vars({head, meta, args}, bindings),
    do: {substitute_vars(head, bindings), meta, substitute_vars(args, bindings)}

  def substitute_vars(other, _bindings), do: other

  defp expand_aliases(ast, env), do: Macro.prewalk(ast, &expand_alias(&1, env))

  defp expand_alias({:__aliases__, _, _} = node, env), do: Macro.expand(node, env)
  defp expand_alias({:__MODULE__, _, _} = node, env), do: Macro.expand(node, env)
  defp expand_alias(node, _env), do: node

  defp localize_module_types(ast, module) do
    Macro.prewalk(ast, fn
      {{:., _, [remote, fun]}, meta, args}
      when is_atom(fun) and is_list(args) and remote == module ->
        {fun, meta, args}

      node ->
        node
    end)
  end
end
