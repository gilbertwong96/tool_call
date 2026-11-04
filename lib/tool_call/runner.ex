defmodule ToolCall.Runner do
  @moduledoc """
  Validates and dispatches a decoded argument map to the tool function.

  Validation is generated from the same IR that produced the schema, so the
  parameter set, its names and its types cannot drift between the two.
  """

  require Logger

  alias ToolCall.{Coerce, Typespec}
  alias ToolCall.IR.{Param, Tool, Type}

  @doc """
  Runs a tool by name.

  `args` uses string keys, as JSON decodes them, including nested object values;
  `keyword(t)` values also accept atom keys because a keyword list is their value
  domain. Invalid UTF-8 binaries in string arguments become
  `{:invalid_argument, {name, {:invalid_utf8, value}}}` errors.

  Runtime tool lists are validated before dispatch. Compiled tools can use
  `run_prepared/4` to skip that validation.
  """
  @spec run(module(), [Tool.t()], atom() | String.t(), term()) ::
          {:ok, term()} | {:error, term()}
  def run(module, tools, name, args) when is_map(args) do
    tools = Enum.map(tools, &Typespec.validate_tool!/1)
    run_prepared(module, tools, name, args)
  end

  def run(_module, _tools, _name, args), do: {:error, {:invalid_arguments, args}}

  @doc """
  Internal fast path for already prepared tools.

  This skips runtime IR validation. Callers must pass tools prepared by
  `ToolCall.Typespec.validate_tool!/1`; use `run/4` for arbitrary runtime tools.
  """
  @spec run_prepared(module(), [Tool.t()], atom() | String.t(), term()) ::
          {:ok, term()} | {:error, term()}
  def run_prepared(module, tools, name, args) when is_map(args) do
    name = to_string(name)

    with {:ok, tool} <- fetch(tools, name),
         :ok <- reject_non_string_keys(args),
         :ok <- reject_nested_non_string_keys(tool, args),
         :ok <- reject_unknown_arguments(tool, args),
         {:ok, values} <- coerce(tool, args),
         {:ok, positional} <- positional(tool, values) do
      invoke(module, tool, positional)
    end
  end

  def run_prepared(_module, _tools, _name, args), do: {:error, {:invalid_arguments, args}}

  # Reporting a known name as "unknown" because it arrived as an atom is
  # misleading; JSON objects decode to strings, so say what is wrong.
  defp reject_non_string_keys(args) do
    case Enum.reject(Map.keys(args), &is_binary/1) do
      [] -> :ok
      keys -> {:error, {:non_string_arguments, keys}}
    end
  end

  defp reject_nested_non_string_keys(%Tool{} = tool, args) do
    keys =
      Enum.flat_map(tool.params, fn param ->
        case Map.fetch(args, param.name) do
          {:ok, value} -> nested_non_string_keys(param.type, value)
          :error -> []
        end
      end)
      |> Enum.uniq()

    case keys do
      [] -> :ok
      keys -> {:error, {:non_string_arguments, keys}}
    end
  end

  defp nested_non_string_keys(%Type{kind: :object, source: :keyword} = type, value)
       when is_map(value) do
    additional = type.additional

    Enum.flat_map(value, fn {_key, item} ->
      nested_non_string_keys(additional || %Type{kind: :any}, item)
    end)
  end

  defp nested_non_string_keys(%Type{kind: :object} = type, value) when is_map(value) do
    fields = type.fields || []
    bad_keys = value |> Map.keys() |> Enum.reject(&is_binary/1)

    nested =
      Enum.flat_map(value, fn {key, item} ->
        field = Enum.find(fields, &(&1.name == key or &1.key == key))
        nested_type = if field, do: field.type, else: type.additional

        if nested_type,
          do: nested_non_string_keys(nested_type, item),
          else: []
      end)

    bad_keys ++ nested
  end

  defp nested_non_string_keys(%Type{kind: :array, items: items}, value) when is_list(value) do
    Enum.flat_map(value, &nested_non_string_keys(items || %Type{kind: :any}, &1))
  end

  defp nested_non_string_keys(%Type{kind: :tuple, items: items}, value)
       when is_list(value) or is_tuple(value) do
    values = if is_tuple(value), do: Tuple.to_list(value), else: value
    items = items || []

    values
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} ->
      case Enum.at(items, index) do
        nil -> []
        type -> nested_non_string_keys(type, item)
      end
    end)
  end

  defp nested_non_string_keys(%Type{kind: :union} = type, value) do
    variants = type.variants || []

    if Enum.any?(variants, &(&1.kind in [:any, :unsupported])) do
      []
    else
      variants
      |> Enum.flat_map(&nested_non_string_keys(&1, value))
      |> Enum.uniq()
    end
  end

  defp nested_non_string_keys(%Type{}, _value), do: []

  defp fetch(tools, name) do
    case Enum.find(tools, &(&1.name == name)) do
      nil -> {:error, {:unknown_tool, name, Enum.map(tools, & &1.name)}}
      tool -> {:ok, %{tool | params: tool.params || []}}
    end
  end

  defp reject_unknown_arguments(%Tool{} = tool, args) do
    known = MapSet.new(tool.params, & &1.name)

    case Enum.reject(Map.keys(args), &MapSet.member?(known, &1)) do
      [] -> :ok
      unknown -> {:error, {:unknown_arguments, Enum.map(unknown, &to_string/1)}}
    end
  end

  defp coerce(%Tool{} = tool, args) do
    Enum.reduce_while(tool.params, {:ok, %{}}, fn param, {:ok, acc} ->
      case coerce_param(param, args) do
        {:ok, :missing} -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, Map.put(acc, param.name, value)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp coerce_param(%Param{} = param, args) do
    case Map.fetch(args, param.name) do
      {:ok, nil} when not param.required ->
        if Coerce.accepts_nil?(param.type),
          do: coerce_value(param, nil),
          else: {:ok, :missing}

      {:ok, raw} ->
        coerce_value(param, raw)

      :error ->
        missing_param(param)
    end
  end

  defp coerce_value(%Param{} = param, raw) do
    case Coerce.param(param, raw) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, {:invalid_argument, reason}}
    end
  end

  defp missing_param(%Param{required: true} = param),
    do: {:error, {:missing_argument, param.name}}

  defp missing_param(%Param{}), do: {:ok, :missing}

  # Elixir fills defaults in declaration order: a reduced-arity call receives
  # every required argument plus a prefix of the optional arguments. A required
  # argument after an omitted optional one is fine; a later optional argument
  # after an omitted optional one is not, because apply/3 would shift it into
  # the wrong position.
  defp positional(%Tool{} = tool, values) do
    params = tool.params || []
    provided = Enum.filter(params, &Map.has_key?(values, &1.name))
    optional = Enum.filter(params, &(not &1.required))
    provided_optional = Enum.filter(optional, &Map.has_key?(values, &1.name))

    if optional_prefix?(provided_optional, optional) do
      {:ok, Enum.map(provided, &Map.fetch!(values, &1.name))}
    else
      {missing, dropped} = first_optional_gap(optional, values)
      {:error, {:argument_gap, missing.name, Enum.map(dropped, & &1.name)}}
    end
  end

  defp optional_prefix?(provided, optional), do: Enum.take(optional, length(provided)) == provided

  defp first_optional_gap(optional, values) do
    {missing, dropped, _seen_missing?} =
      Enum.reduce(optional, {nil, [], false}, fn param, {missing, dropped, seen_missing?} ->
        cond do
          not Map.has_key?(values, param.name) ->
            {missing || param, dropped, true}

          seen_missing? ->
            {missing, dropped ++ [param], true}

          true ->
            {missing, dropped, false}
        end
      end)

    {missing, dropped}
  end

  defp invoke(module, %Tool{} = tool, args) do
    result =
      try do
        apply(module, tool.fun, args)
      rescue
        exception ->
          Logger.error(Exception.format(:error, exception, __STACKTRACE__))
          {:error, {:raised, Exception.message(exception)}}
      catch
        :throw, value -> {:error, {:thrown, value}}
        :exit, reason -> {:error, {:exited, reason}}
      end

    normalize(result)
  end

  defp normalize({:ok, _value} = ok), do: ok
  defp normalize({:error, _reason} = error), do: error
  defp normalize(other), do: {:ok, other}
end
