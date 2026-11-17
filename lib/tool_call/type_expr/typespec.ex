defmodule ToolCall.TypeExpr.Typespec do
  @moduledoc """
  Translates normalized, local-type-expanded typespec AST into `ToolCall.TypeExpr`.

  Aliases, `__MODULE__` references, and `when` bindings must already be resolved
  by `ToolCall.TypeAst` and local-type expansion. This adapter does not resolve
  providers or structs; `ToolCall.TypeCompiler` owns those steps.
  """

  alias ToolCall.{Patterns, TypeAst}
  alias ToolCall.TypeExpr

  @unrepresentable [:fun, :pid, :port, :reference, :mfa, :no_return, :none]

  @spec from_ast(term()) :: TypeExpr.t()
  def from_ast(nil), do: {:literal, nil}
  def from_ast(true), do: {:literal, true}
  def from_ast(false), do: {:literal, false}

  def from_ast(atom) when is_atom(atom), do: {:literal, atom}
  def from_ast(integer) when is_integer(integer), do: {:literal, integer}
  def from_ast(float) when is_float(float), do: {:literal, float}
  def from_ast(binary) when is_binary(binary), do: {:literal, binary}

  def from_ast({:-, _, [number]}) when is_number(number), do: from_ast(-number)

  def from_ast({:|, _, _} = union) do
    {:union, flatten_union(union)}
  end

  def from_ast({:.., _, [low, high]}) do
    case {TypeAst.int_literal(low), TypeAst.int_literal(high)} do
      {{:ok, low}, {:ok, high}} -> {:integer_range, low, high}
      _other -> :any
    end
  end

  def from_ast({:%, _, [module, {:%{}, _, _fields}]}) when is_atom(module) do
    {:remote, module, :t, []}
  end

  def from_ast({:%{}, _, pairs}), do: map(pairs)
  def from_ast({:{}, _, elements}), do: {:tuple, Enum.map(elements, &from_ast/1)}

  def from_ast({left, right}) do
    {:tuple, [from_ast(left), from_ast(right)]}
  end

  def from_ast([{:->, _, _}]), do: {:unsupported, :fun}

  def from_ast([type, {:..., _, []}]) do
    {:nonempty_list, from_ast(type)}
  end

  def from_ast([type]), do: {:list, from_ast(type)}
  def from_ast([]), do: {:list, :any}

  def from_ast({{:., _, [:tool_call_ref, :ref]}, _, [ref]}) when is_binary(ref),
    do: {:ref, ref}

  def from_ast({{:., _, [module, function]}, _, args}) when is_atom(module) do
    {:remote, module, function, Enum.map(args, &from_ast/1)}
  end

  def from_ast({name, _meta, context}) when is_atom(name) and is_atom(context),
    do: {:var, name}

  def from_ast({name, _, args}) when is_atom(name) and is_list(args) do
    local(name, args)
  end

  # Any shape neither this adapter nor `ToolCall.Typespec` understands stays
  # "unknown" rather than "known but unrepresentable": an unknown nested value
  # renders as `{}` and keeps the tool, while `:unsupported` would hide it.
  def from_ast(_other), do: :any

  defp flatten_union(ast), do: ast |> flatten_union([]) |> Enum.reverse()

  defp flatten_union({:|, _, [left, right]}, acc),
    do: flatten_union(right, flatten_union(left, acc))

  defp flatten_union(type, acc), do: [from_ast(type) | acc]

  defp map(pairs) do
    {fields, additional} =
      Enum.reduce(pairs, {[], nil}, fn
        {{:required, _, [key]}, type}, {fields, additional} when is_atom(key) ->
          {[{key, from_ast(type), true} | fields], additional}

        {{:optional, _, [key]}, type}, {fields, additional} when is_atom(key) ->
          {[{key, from_ast(type), false} | fields], additional}

        {key, type}, {fields, additional} when is_atom(key) ->
          {[{key, from_ast(type), true} | fields], additional}

        {_key_type, type}, {fields, _additional} ->
          {fields, from_ast(type)}
      end)

    {:map, Enum.reverse(fields), additional}
  end

  defp local(:integer, []), do: {:primitive, :integer}
  defp local(:non_neg_integer, []), do: {:annotated, {:primitive, :integer}, %{minimum: 0}}
  defp local(:pos_integer, []), do: {:annotated, {:primitive, :integer}, %{minimum: 1}}
  defp local(:neg_integer, []), do: {:annotated, {:primitive, :integer}, %{maximum: -1}}
  defp local(:byte, []), do: {:annotated, {:primitive, :integer}, %{minimum: 0, maximum: 255}}
  defp local(:float, []), do: {:primitive, :float}
  defp local(:number, []), do: {:primitive, :number}
  defp local(:atom, []), do: {:primitive, :atom}
  defp local(:module, []), do: {:primitive, :atom}
  defp local(:boolean, []), do: {:primitive, :boolean}

  defp local(:binary, []), do: string(:binary)
  defp local(:bitstring, []), do: string(:bitstring)
  defp local(:string, []), do: string(:string)
  defp local(:charlist, []), do: string(:charlist)

  defp local(:char, []), do: {:string, %{source: :char, pattern: Patterns.char()}}

  defp local(:nonempty_binary, []),
    do: {:string, %{source: :nonempty_binary, pattern: Patterns.nonempty()}}

  defp local(:nonempty_string, []),
    do: {:string, %{source: :nonempty_string, pattern: Patterns.nonempty()}}

  defp local(:list, []), do: {:list, :any}
  defp local(:list, [type]), do: {:list, from_ast(type)}
  defp local(:nonempty_list, []), do: {:nonempty_list, :any}
  defp local(:nonempty_list, [type]), do: {:nonempty_list, from_ast(type)}

  defp local(:keyword, []), do: {:builtin, :keyword, []}
  defp local(:keyword, [type]), do: {:builtin, :keyword, [from_ast(type)]}
  defp local(:keyword, args), do: {:builtin, :keyword, Enum.map(args, &from_ast/1)}

  defp local(:map, []), do: {:map, [], :any}
  defp local(:tuple, []), do: {:tuple, nil}
  defp local(:as_boolean, [type]), do: from_ast(type)
  defp local(:as_boolean, []), do: {:primitive, :boolean}
  defp local(name, []) when name in [:term, :any], do: :any
  defp local(name, []) when name in @unrepresentable, do: {:unsupported, name}
  defp local(:fun, _args), do: {:unsupported, :fun}
  defp local(:struct, []), do: {:map, [], :any}

  defp local(name, args) do
    {:ref, {name, length(args)}, Enum.map(args, &from_ast/1)}
  end

  defp string(source), do: {:string, %{source: source}}
end
