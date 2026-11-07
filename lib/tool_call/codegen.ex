defmodule ToolCall.Codegen do
  @moduledoc false

  import Bitwise

  alias ToolCall.IR.{Param, Tool, Type}

  @max_optional 6

  @spec runner_clauses([Tool.t()], [String.t()]) :: [Macro.t()]
  def runner_clauses(tools, indirect) do
    tools
    |> Enum.with_index()
    |> Enum.flat_map(fn {tool, index} ->
      clauses(tool, index, tool.name in indirect)
    end)
  end

  defp clauses(tool, index, indirect?) do
    runner = :"__tool_call_run_#{index}__"

    clauses = [
      quote do
        def __run__(unquote(tool.name), args), do: unquote(runner)(args)
        def __run__(unquote(tool.fun), args), do: unquote(runner)(args)
      end
    ]

    definition =
      if fast_tool?(tool),
        do: fast_runner(tool, runner, indirect?),
        else: generic_runner(tool, runner)

    clauses ++ [definition]
  end

  defp fast_runner(tool, runner, indirect?) do
    params = tool.params || []
    vars = vars(params)
    optional = Enum.reject(params, & &1.required)
    known = Enum.map(params, & &1.name)

    required_clauses =
      params
      |> Enum.with_index()
      |> Enum.filter(fn {param, _index} -> param.required end)
      |> Enum.map(fn {param, index} -> arg_clause(param, vars[index], index) end)

    present_vars =
      optional
      |> Enum.with_index()
      |> Enum.map(fn {_param, index} -> present_var(index) end)

    present_clauses = Enum.zip(optional, present_vars) |> Enum.map(&present_clause/1)
    body = optional_body(tool, params, vars, optional, present_vars, indirect?)

    clauses = [check_clause(known)] ++ required_clauses ++ present_clauses
    with_ast = {:with, [], clauses ++ [[do: body]]}

    quote do
      defp unquote(runner)(args) when is_map(args) do
        unquote(with_ast)
      end

      defp unquote(runner)(args), do: {:error, {:invalid_arguments, args}}
    end
  end

  defp generic_runner(tool, runner) do
    known = Enum.map(tool.params || [], & &1.name)
    nested? = Enum.any?(tool.params || [], &nested_key_check?(&1.type))

    quote do
      defp unquote(runner)(args) do
        ToolCall.Runner.run_prepared_tool(
          __MODULE__,
          unquote(Macro.escape(tool)),
          args,
          unquote(nested?),
          unquote(known)
        )
      end
    end
  end

  defp optional_body(tool, params, vars, [], _present_vars, indirect?) do
    selected = Enum.map(params, fn param -> vars[Enum.find_index(params, &(&1 == param))] end)
    invoke_ast(tool, selected, indirect?)
  end

  defp optional_body(tool, params, vars, optional, present_vars, indirect?) do
    branches =
      for mask <- 0..(bsl(1, length(optional)) - 1) do
        optional_branch(tool, params, vars, optional, mask, indirect?)
      end

    tuple = quote do: {unquote_splicing(present_vars)}
    {:case, [], [tuple, [do: branches]]}
  end

  defp optional_branch(tool, params, vars, optional, mask, indirect?) do
    bits = for index <- 0..(length(optional) - 1), do: band(mask, bsl(1, index)) != 0
    pattern = quote do: {unquote_splicing(bits)}

    if valid_prefix?(bits) do
      clauses =
        optional
        |> Enum.with_index()
        |> Enum.filter(fn {_param, index} -> Enum.at(bits, index) end)
        |> Enum.map(fn {param, _optional_index} ->
          param_index = Enum.find_index(params, &(&1 == param))
          arg_clause(param, vars[param_index], param_index)
        end)

      selected =
        params
        |> Enum.filter(fn param ->
          param.required or Enum.at(bits, Enum.find_index(optional, &(&1 == param)))
        end)
        |> Enum.map(fn param -> vars[Enum.find_index(params, &(&1 == param))] end)

      body = optional_branch_body(tool, selected, clauses, indirect?)
      {:->, [], [[pattern], body]}
    else
      missing_index = Enum.find_index(bits, &(not &1))
      missing = Enum.at(optional, missing_index)

      dropped =
        optional
        |> Enum.with_index()
        |> Enum.filter(fn {_p, i} -> i > missing_index and Enum.at(bits, i) end)
        |> Enum.map(fn {p, _i} -> p.name end)

      error =
        quote do
          {:error, {:argument_gap, unquote(missing.name), unquote(dropped)}}
        end

      {:->, [], [[pattern], error]}
    end
  end

  defp optional_branch_body(tool, selected, [], indirect?) do
    invoke_ast(tool, selected, indirect?)
  end

  defp optional_branch_body(tool, selected, clauses, indirect?) do
    {:with, [], clauses ++ [[do: invoke_ast(tool, selected, indirect?)]]}
  end

  defp check_clause(known) do
    quote do
      :ok <- ToolCall.Runner.check_arguments(args, unquote(known))
    end
  end

  defp present_clause({param, var}) do
    quote do
      unquote(var) <- unquote(present_ast(param))
    end
  end

  defp present_ast(%Param{name: name, type: type}) do
    accepts_nil = accepts_nil?(type)

    quote do
      case Map.fetch(args, unquote(name)) do
        {:ok, nil} -> unquote(accepts_nil)
        {:ok, _value} -> true
        :error -> false
      end
    end
  end

  defp arg_clause(%Param{name: name, type: type}, var, index) do
    value = Macro.var(:"value_#{index}", __MODULE__)
    coerce = coerce_ast(type, value)

    quote do
      {:ok, unquote(var)} <-
        case Map.fetch(args, unquote(name)) do
          {:ok, unquote(value)} ->
            case unquote(coerce) do
              {:ok, unquote(var)} -> {:ok, unquote(var)}
              {:error, reason} -> {:error, {:invalid_argument, {unquote(name), reason}}}
            end

          :error ->
            {:error, {:missing_argument, unquote(name)}}
        end
    end
  end

  defp invoke_ast(tool, args, indirect?) do
    call =
      if indirect? do
        quote do: apply(__MODULE__, unquote(tool.fun), unquote(args))
      else
        {tool.fun, [], args}
      end

    quote do
      try do
        ToolCall.Runner.normalize(unquote(call))
      rescue
        exception ->
          ToolCall.Runner.raised(exception, __STACKTRACE__)
      catch
        :throw, value -> ToolCall.Runner.caught(:throw, value)
        :exit, reason -> ToolCall.Runner.caught(:exit, reason)
      end
    end
  end

  defp coerce_ast(%Type{kind: :integer, minimum: minimum, maximum: maximum}, value) do
    quote do: ToolCall.Coerce.simple_integer(unquote(value), unquote(minimum), unquote(maximum))
  end

  defp coerce_ast(%Type{kind: :float, minimum: minimum, maximum: maximum}, value) do
    quote do: ToolCall.Coerce.simple_float(unquote(value), unquote(minimum), unquote(maximum))
  end

  defp coerce_ast(%Type{kind: :number, minimum: minimum, maximum: maximum}, value) do
    quote do: ToolCall.Coerce.simple_number(unquote(value), unquote(minimum), unquote(maximum))
  end

  defp coerce_ast(%Type{kind: :string}, value) do
    quote do: ToolCall.Coerce.simple_string(unquote(value))
  end

  defp coerce_ast(%Type{kind: :boolean}, value) do
    quote do: ToolCall.Coerce.simple_boolean(unquote(value))
  end

  defp coerce_ast(%Type{kind: :atom}, value) do
    quote do: ToolCall.Coerce.simple_atom(unquote(value))
  end

  defp coerce_ast(%Type{kind: :null}, value) do
    quote do: ToolCall.Coerce.simple_null(unquote(value))
  end

  defp coerce_ast(%Type{kind: :any}, value) do
    quote do: ToolCall.Coerce.simple_any(unquote(value))
  end

  defp vars(params) do
    params
    |> Enum.with_index()
    |> Map.new(fn {_param, index} -> {index, Macro.var(:"arg_#{index}", __MODULE__)} end)
  end

  defp present_var(index), do: Macro.var(:"present_#{index}", __MODULE__)

  defp fast_tool?(%Tool{params: params}) do
    params = params || []
    optional = Enum.reject(params, & &1.required)

    length(optional) <= @max_optional and
      Enum.all?(params, fn param -> param.wire == :number and simple_type?(param.type) end)
  end

  defp simple_type?(%Type{kind: :integer, transform: nil, nullable: false}), do: true
  defp simple_type?(%Type{kind: :float, transform: nil, nullable: false}), do: true
  defp simple_type?(%Type{kind: :number, transform: nil, nullable: false}), do: true
  defp simple_type?(%Type{kind: :boolean, transform: nil, nullable: false}), do: true
  defp simple_type?(%Type{kind: :atom, transform: nil, nullable: false}), do: true
  defp simple_type?(%Type{kind: :any, transform: nil, nullable: false}), do: true
  defp simple_type?(%Type{kind: :null, transform: nil, nullable: false}), do: true

  defp simple_type?(%Type{
         kind: :string,
         source: source,
         pattern: nil,
         transform: nil,
         nullable: false
       })
       when source not in [:char, :charlist, :bitstring],
       do: true

  defp simple_type?(_type), do: false

  defp accepts_nil?(%Type{kind: :any}), do: true
  defp accepts_nil?(%Type{kind: :null}), do: true
  defp accepts_nil?(_type), do: false

  defp nested_key_check?(%Type{kind: :object}), do: true
  defp nested_key_check?(%Type{kind: :array}), do: true
  defp nested_key_check?(%Type{kind: :tuple}), do: true

  defp nested_key_check?(%Type{kind: :union, variants: variants}),
    do: Enum.any?(variants || [], &nested_key_check?/1)

  defp nested_key_check?(_type), do: false

  defp valid_prefix?([]), do: true
  defp valid_prefix?([false | rest]), do: not Enum.any?(rest)
  defp valid_prefix?([true | rest]), do: valid_prefix?(rest)
end
