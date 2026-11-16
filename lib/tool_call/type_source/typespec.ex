defmodule ToolCall.TypeSource.Typespec do
  @moduledoc false

  @behaviour ToolCall.TypeSource

  alias ToolCall.TypeAst
  alias ToolCall.TypeSource.{Declaration, Param}

  @impl true
  def load(module, _env) when is_atom(module) do
    %{specs: module |> Module.get_attribute(:spec) |> List.wrap()}
  end

  @impl true
  def fetch(%{specs: specs}, name, arity) when is_atom(name) and is_integer(arity) do
    matching =
      for {:spec, ast, _location} <- specs,
          spec_signature(ast) == {name, arity},
          do: ast

    matching = Enum.reverse(matching)

    case matching do
      [] ->
        {:error, missing_messages(specs, name, arity)}

      [raw_spec | _rest] ->
        {spec, constraints} = unwrap_spec(raw_spec)
        {:"::", _, [head, return_ast]} = spec
        {^name, _, args} = head

        {:ok,
         %Declaration{
           name: name,
           arity: arity,
           params: Enum.map(args, &param/1),
           return: return_ast,
           bindings: constraint_bindings(constraints),
           source: spec,
           indirect?: match?({:no_return, _, []}, return_ast),
           warnings: overload_warnings(name, arity, length(matching))
         }}
    end
  end

  defp param({:"::", _, [{var, _, context}, type]})
       when is_atom(var) and is_atom(context) do
    if underscore?(var) do
      %Param{name: nil, type: type, named?: false}
    else
      %Param{name: var, type: type, named?: true}
    end
  end

  defp param(type), do: %Param{name: nil, type: type, named?: false}

  defp underscore?(name), do: String.starts_with?(Atom.to_string(name), "_")

  defp missing_messages(specs, name, arity) do
    reduced =
      for {:spec, ast, _location} <- specs,
          {^name, spec_arity} <- [spec_signature(ast)],
          spec_arity < arity,
          uniq: true,
          do: spec_arity

    case reduced do
      [] ->
        [
          "#{name}/#{arity} has no @spec; skipped. A tool without a typespec cannot be described."
        ]

      arities ->
        existing = Enum.map_join(Enum.sort(arities), ", ", &"#{name}/#{&1}")

        [
          "#{name}/#{arity} has no @spec; found #{existing} instead. A reduced arity " <>
            "does not describe the defaulted arguments; add a spec for the full arity."
        ]
    end
  end

  defp overload_warnings(_name, _arity, count) when count < 2, do: []

  defp overload_warnings(name, arity, count) do
    [
      "#{name}/#{arity} has #{count} @spec clauses; using the first one. " <>
        "Overloaded tools cannot be expressed as a single JSON Schema."
    ]
  end

  defp unwrap_spec({:when, _, [spec, constraints]}) when is_list(constraints),
    do: {spec, constraints}

  defp unwrap_spec(spec), do: {spec, []}

  @doc false
  @spec spec_signature(term()) :: {atom(), non_neg_integer()} | nil
  def spec_signature(spec) do
    case unwrap_spec(spec) do
      {{:"::", _, [{fun, _, args}, _return]}, _constraints}
      when is_atom(fun) and is_list(args) ->
        {fun, length(args)}

      _other ->
        nil
    end
  end

  # `@spec id(x) :: x when x: integer()` constrains a type variable, but a tool
  # schema has no variables: bind them to the type the spec gives.
  @doc false
  @spec constraint_bindings(list()) :: map()
  def constraint_bindings(constraints) do
    bindings =
      Enum.reduce(constraints, %{}, fn
        {name, type_ast}, acc when is_atom(name) ->
          Map.put(acc, name, TypeAst.substitute_vars(type_ast, acc))

        _other, acc ->
          acc
      end)

    # A constraint may refer to a variable declared after it (`when x: [t],
    # t: integer()`); the reverse pass resolves that direction without looping
    # on recursive constraints such as `when x: [x]`.
    constraints
    |> Enum.reverse()
    |> Enum.reduce(bindings, fn
      {name, type_ast}, acc when is_atom(name) ->
        Map.put(acc, name, TypeAst.substitute_vars(type_ast, acc))

      _other, acc ->
        acc
    end)
  end
end
