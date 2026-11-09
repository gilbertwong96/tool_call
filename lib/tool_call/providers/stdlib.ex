defmodule ToolCall.Providers.Stdlib do
  @moduledoc false
  @behaviour ToolCall.TypeProvider

  alias ToolCall.IR.Type

  @impl true
  def resolve(String, :t, []), do: {:ok, %Type{kind: :string, source: {String, :t}}}

  def resolve(Path, :t, []), do: {:ok, %Type{kind: :string, source: {Path, :t}}}

  def resolve(Keyword, :t, args) do
    case args do
      [] -> {:ok, keyword_type(%Type{kind: :any})}
      [type] -> {:ok, keyword_type(type)}
      other -> {:ok, %Type{kind: :any, source: {:keyword, other}}}
    end
  end

  def resolve(module, :t, []) when module in [Date, Time, DateTime, NaiveDateTime] do
    {:ok, calendar_type(module)}
  end

  def resolve(_module, _function, _args), do: :error

  @doc false
  def keyword_type(value) do
    %Type{
      kind: :object,
      fields: [],
      additional: value,
      source: :keyword,
      transform: {__MODULE__, :coerce_keyword},
      validator: {__MODULE__, :validate_keyword}
    }
  end

  defp calendar_type(module) do
    %Type{
      kind: :string,
      source: {module, :t},
      format: format(module),
      transform: {__MODULE__, coerce_fun(module)},
      validator: {__MODULE__, validate_fun(module)}
    }
  end

  defp format(Date), do: "date"
  defp format(Time), do: "time"
  defp format(DateTime), do: "date-time"
  defp format(NaiveDateTime), do: nil

  defp validate_fun(Date), do: :validate_date
  defp validate_fun(Time), do: :validate_time
  defp validate_fun(DateTime), do: :validate_datetime
  defp validate_fun(NaiveDateTime), do: :validate_naive_datetime

  @doc false
  def validate_date(_type, value, _defs), do: is_struct(value, Date)

  @doc false
  def validate_time(_type, value, _defs), do: is_struct(value, Time)

  @doc false
  def validate_datetime(_type, value, _defs), do: is_struct(value, DateTime)

  @doc false
  def validate_naive_datetime(_type, value, _defs), do: is_struct(value, NaiveDateTime)

  @doc false
  def validate_keyword(%Type{additional: additional}, value, defs) when is_list(value) do
    proper_list?(value) and
      Enum.all?(value, fn
        {key, item} when is_atom(key) -> element_valid?(additional, item, defs)
        _other -> false
      end)
  end

  def validate_keyword(_type, _value, _defs), do: false

  defp element_valid?(nil, _item, _defs), do: true
  defp element_valid?(%Type{kind: :any}, _item, _defs), do: true

  defp element_valid?(%Type{} = type, item, defs),
    do: ToolCall.Validate.valid?(type, item, defs) == :ok

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_other), do: false

  defp coerce_fun(Date), do: :coerce_date
  defp coerce_fun(Time), do: :coerce_time
  defp coerce_fun(DateTime), do: :coerce_datetime
  defp coerce_fun(NaiveDateTime), do: :coerce_naive_datetime

  @doc false
  def coerce_keyword(map) when is_map(map) do
    map
    |> Enum.reduce_while({:ok, []}, fn {key, value}, {:ok, acc} ->
      case keyword_key(key) do
        {:ok, atom} -> {:cont, {:ok, [{atom, value} | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      error -> error
    end
  end

  def coerce_keyword(value), do: {:error, {:expected_object, value}}

  @doc false
  def coerce_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, {:invalid_date, value}}
    end
  end

  def coerce_date(value), do: {:error, {:invalid_date, value}}

  @doc false
  def coerce_time(value) when is_binary(value) do
    case Time.from_iso8601(value) do
      {:ok, time} -> {:ok, time}
      {:error, _reason} -> {:error, {:invalid_time, value}}
    end
  end

  def coerce_time(value), do: {:error, {:invalid_time, value}}

  @doc false
  def coerce_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid_datetime, value}}
    end
  end

  def coerce_datetime(value), do: {:error, {:invalid_datetime, value}}

  @doc false
  def coerce_naive_datetime(value) when is_binary(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid_naive_datetime, value}}
    end
  end

  def coerce_naive_datetime(value), do: {:error, {:invalid_naive_datetime, value}}

  defp keyword_key(key) when is_atom(key), do: {:ok, key}

  defp keyword_key(key) when is_binary(key) do
    if String.valid?(key) do
      {:ok, String.to_existing_atom(key)}
    else
      {:error, {:invalid_utf8, key}}
    end
  rescue
    ArgumentError -> {:error, {:unknown_atom, key}}
  end

  defp keyword_key(key), do: {:error, {:invalid_key, key}}
end
