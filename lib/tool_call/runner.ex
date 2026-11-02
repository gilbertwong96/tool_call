defmodule ToolCall.Runner do
  @moduledoc """
  Validates and dispatches a decoded argument map to the tool function.

  Validation is generated from the same IR that produced the schema, so the
  parameter set, its names and its types cannot drift between the two.
  """

  require Logger

  alias ToolCall.Coerce
  alias ToolCall.IR.{Param, Tool}

  @doc """
  Runs a tool by name.

  `args` uses string keys, as JSON decodes them, including nested object values;
  `keyword(t)` values also accept atom keys because a keyword list is their value
  domain.
  """
  @spec run(module(), [Tool.t()], atom() | String.t(), term()) ::
          {:ok, term()} | {:error, term()}
  def run(module, tools, name, args) when is_map(args) do
    name = to_string(name)

    with {:ok, tool} <- fetch(tools, name),
         :ok <- reject_non_string_keys(args),
         :ok <- reject_unknown_arguments(tool, args),
         {:ok, values} <- coerce(tool, args),
         {:ok, positional} <- positional(tool, values) do
      invoke(module, tool, positional)
    end
  end

  def run(_module, _tools, _name, args), do: {:error, {:invalid_arguments, args}}

  # Reporting a known name as "unknown" because it arrived as an atom is
  # misleading; JSON objects decode to strings, so say what is wrong.
  defp reject_non_string_keys(args) do
    case Enum.reject(Map.keys(args), &is_binary/1) do
      [] -> :ok
      keys -> {:error, {:non_string_arguments, keys}}
    end
  end

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
      {:ok, nil} when not param.required -> {:ok, :missing}
      {:ok, raw} -> coerce_value(param, raw)
      :error -> missing_param(param)
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

  # Default arguments are trailing-only in Elixir, so arguments after the first
  # gap cannot be passed positionally. Silently dropping them would hand the
  # function a different call than the model asked for.
  defp positional(%Tool{} = tool, values) do
    {args, missing, dropped} =
      Enum.reduce(tool.params, {[], nil, []}, fn param, {args, missing, dropped} ->
        case {Map.fetch(values, param.name), missing} do
          {{:ok, value}, nil} -> {[value | args], nil, dropped}
          {{:ok, _value}, missing} -> {args, missing, dropped ++ [param.name]}
          {:error, nil} -> {args, param.name, dropped}
          {:error, _missing} -> {args, missing, dropped}
        end
      end)

    case dropped do
      [] -> {:ok, Enum.reverse(args)}
      _ -> {:error, {:argument_gap, missing, dropped}}
    end
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
