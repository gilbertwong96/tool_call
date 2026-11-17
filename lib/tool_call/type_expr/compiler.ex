defmodule ToolCall.TypeExpr.Compiler do
  @moduledoc """
  Lowers `ToolCall.TypeExpr` into `ToolCall.IR.Type`.

  Provider resolution, struct markers, and union normalization happen here, so
  the type expression itself can stay source-neutral and unresolved.
  """

  alias ToolCall.IR.{Field, Type}
  alias ToolCall.{Patterns, Providers.Stdlib, Typespec}
  alias ToolCall.TypeExpr.Projection

  @spec to_type(ToolCall.TypeExpr.t(), [module()]) :: Type.t()
  def to_type(:any, _providers), do: %Type{kind: :any}
  def to_type(:none, _providers), do: %Type{kind: :unsupported, source: :none}

  def to_type({:literal, nil}, _providers), do: %Type{kind: :null, source: nil}

  def to_type({:literal, value}, _providers) when is_boolean(value),
    do: %Type{kind: :enum, values: [value], source: value}

  def to_type({:literal, value}, _providers) when is_atom(value),
    do: %Type{kind: :enum, values: [value], source: value}

  def to_type({:literal, value}, _providers) when is_integer(value),
    do: %Type{kind: :integer, minimum: value, maximum: value, source: value}

  def to_type({:literal, value}, _providers) when is_float(value),
    do: %Type{kind: :float, source: value}

  def to_type({:literal, value}, _providers) when is_binary(value),
    do: %Type{kind: :enum, values: [value], source: value}

  def to_type({:primitive, kind}, _providers), do: primitive(kind)

  def to_type({:integer_range, low, high}, _providers),
    do: %Type{kind: :integer, minimum: low, maximum: high}

  def to_type({:enum, values}, _providers) when is_list(values),
    do: %Type{kind: :enum, values: values}

  def to_type({:string, metadata}, _providers), do: string(metadata)
  def to_type({:list, item}, providers), do: %Type{kind: :array, items: to_type(item, providers)}

  def to_type({:nonempty_list, item}, providers) do
    %Type{kind: :array, items: to_type(item, providers), minimum: 1}
  end

  def to_type({:tuple, nil}, _providers), do: %Type{kind: :tuple, items: nil}

  def to_type({:tuple, items}, providers),
    do: %Type{kind: :tuple, items: Enum.map(items, &to_type(&1, providers))}

  def to_type({:map, fields, additional}, providers) do
    %Type{
      kind: :object,
      fields:
        Enum.map(fields, fn {key, type, required?} ->
          %Field{
            name: Atom.to_string(key),
            key: key,
            type: to_type(type, providers),
            required: required?
          }
        end),
      additional: if(additional, do: to_type(additional, providers), else: nil)
    }
  end

  def to_type({:union, variants}, providers) do
    Typespec.union_type(Enum.map(variants, &to_type(&1, providers)))
  end

  def to_type({:annotated, type, metadata}, providers) do
    type
    |> to_type(providers)
    |> put_meta(metadata)
  end

  def to_type({:intersection, variants}, providers), do: projection(variants, providers)

  def to_type({:negation, _type}, _providers), do: %Type{kind: :unsupported, source: :negation}

  def to_type({:ref, ref}, _providers), do: %Type{kind: :ref, ref: ref}

  def to_type({:ref, {name, arity}, _args}, _providers),
    do: %Type{kind: :any, source: {name, arity}}

  def to_type({:local_ref, index}, _providers),
    do: %Type{kind: :any, source: {:local_ref, index}}

  def to_type({:var, name}, _providers), do: %Type{kind: :any, source: {:var, name}}

  def to_type({:remote, module, function, args}, providers) do
    Typespec.resolve_remote(module, function, Enum.map(args, &to_type(&1, providers)), providers)
  end

  def to_type({:builtin, :keyword, args}, providers) do
    argument =
      case args do
        [] -> %Type{kind: :any}
        [type] -> to_type(type, providers)
        types -> %Type{kind: :any, source: {:keyword, types}}
      end

    Stdlib.keyword_type(argument)
  end

  def to_type({:builtin, name, _args}, _providers),
    do: %Type{kind: :unsupported, source: {:builtin, name}}

  def to_type({:dynamic, _type}, _providers), do: %Type{kind: :any, source: :dynamic}
  def to_type({:unsupported, reason}, _providers), do: %Type{kind: :unsupported, source: reason}

  defp projection([], _providers), do: %Type{kind: :unsupported, source: :intersection}

  defp projection([only], providers), do: to_type(only, providers)

  defp projection([first | rest], providers) do
    Enum.reduce_while(rest, {:ok, first}, fn variant, {:ok, acc} ->
      case Projection.intersect(acc, variant) do
        {:ok, result} -> {:cont, {:ok, result}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, result} -> to_type(result, providers)
      :error -> %Type{kind: :unsupported, source: :intersection}
    end
  end

  defp put_meta(type, metadata) do
    type
    |> put_minimum(Map.get(metadata, :minimum))
    |> put_maximum(Map.get(metadata, :maximum))
    |> put_pattern(Map.get(metadata, :pattern))
    |> put_format(Map.get(metadata, :format))
    |> put_source(Map.get(metadata, :source))
  end

  defp put_minimum(type, nil), do: type
  defp put_minimum(type, value), do: %{type | minimum: value}

  defp put_maximum(type, nil), do: type
  defp put_maximum(type, value), do: %{type | maximum: value}

  defp put_pattern(type, nil), do: type

  defp put_pattern(type, pattern) do
    %{
      type
      | pattern: pattern,
        pattern_regex: Patterns.regex(pattern) || Regex.compile!(pattern, "u")
    }
  end

  defp put_format(type, nil), do: type
  defp put_format(type, format), do: %{type | format: format}

  defp put_source(type, nil), do: type
  defp put_source(type, source), do: %{type | source: source}

  defp primitive(:integer), do: %Type{kind: :integer}
  defp primitive(:float), do: %Type{kind: :float}
  defp primitive(:number), do: %Type{kind: :number}
  defp primitive(:boolean), do: %Type{kind: :boolean}
  defp primitive(:atom), do: %Type{kind: :atom}
  defp primitive(:string), do: %Type{kind: :string}
  defp primitive(kind), do: %Type{kind: :unsupported, source: {:primitive, kind}}

  defp string(metadata) do
    pattern = Map.get(metadata, :pattern)

    %Type{
      kind: :string,
      source: Map.get(metadata, :source),
      pattern: pattern,
      pattern_regex: if(pattern, do: Patterns.regex(pattern) || Regex.compile!(pattern, "u"))
    }
    |> put_format(Map.get(metadata, :format))
  end
end
