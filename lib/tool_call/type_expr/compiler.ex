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
  def to_type(expression, providers) do
    case ToolCall.TypeExpr.validate(expression) do
      :ok -> do_type(expression, providers)
      {:error, _reason} -> %Type{kind: :unsupported, source: {:invalid_type_expr, expression}}
    end
  end

  defp do_type(:any, _providers), do: %Type{kind: :any}
  defp do_type(:none, _providers), do: %Type{kind: :unsupported, source: :none}

  defp do_type({:literal, nil}, _providers), do: %Type{kind: :null, source: nil}

  defp do_type({:literal, value}, _providers) when is_boolean(value),
    do: %Type{kind: :enum, values: [value], source: value}

  defp do_type({:literal, value}, _providers) when is_atom(value),
    do: %Type{kind: :enum, values: [value], source: value}

  defp do_type({:literal, value}, _providers) when is_integer(value),
    do: %Type{kind: :integer, minimum: value, maximum: value, source: value}

  defp do_type({:literal, value}, _providers) when is_float(value),
    do: %Type{kind: :float, source: value}

  defp do_type({:literal, value}, _providers) when is_binary(value),
    do: %Type{kind: :enum, values: [value], source: value}

  # A literal that is not a JSON scalar cannot be described, but it must not
  # crash the compiler.
  defp do_type({:literal, value}, _providers),
    do: %Type{kind: :unsupported, source: {:literal, value}}

  defp do_type({:primitive, kind}, _providers), do: primitive(kind)

  defp do_type({:integer_range, low, high}, _providers),
    do: %Type{kind: :integer, minimum: low, maximum: high}

  defp do_type({:enum, values}, _providers) when is_list(values),
    do: %Type{kind: :enum, values: values}

  defp do_type({:string, metadata}, _providers) when is_map(metadata), do: string(metadata)
  defp do_type({:list, item}, providers), do: %Type{kind: :array, items: do_type(item, providers)}

  defp do_type({:nonempty_list, item}, providers) do
    %Type{kind: :array, items: do_type(item, providers), minimum: 1}
  end

  defp do_type({:tuple, nil}, _providers), do: %Type{kind: :tuple, items: nil}

  defp do_type({:tuple, items}, providers) when is_list(items),
    do: %Type{kind: :tuple, items: Enum.map(items, &do_type(&1, providers))}

  defp do_type({:map, fields, additional}, providers) when is_list(fields) do
    %Type{
      kind: :object,
      fields:
        Enum.map(fields, fn {key, type, required?} ->
          %Field{
            name: Atom.to_string(key),
            key: key,
            type: do_type(type, providers),
            required: required?
          }
        end),
      additional: additional_type(additional, providers)
    }
  end

  defp do_type({:union, variants}, providers) when is_list(variants) do
    Typespec.union_type(Enum.map(variants, &do_type(&1, providers)))
  end

  defp do_type({:annotated, type, metadata}, providers) when is_map(metadata) do
    type
    |> do_type(providers)
    |> put_meta(metadata)
  end

  defp do_type({:intersection, variants}, providers) when is_list(variants),
    do: projection(variants, providers)

  defp do_type({:negation, _type}, _providers), do: %Type{kind: :unsupported, source: :negation}

  defp do_type({:ref, ref}, _providers), do: %Type{kind: :ref, ref: ref}

  defp do_type({:ref, {name, arity}, _args}, _providers),
    do: %Type{kind: :any, source: {name, arity}}

  defp do_type({:local_ref, index}, _providers),
    do: %Type{kind: :any, source: {:local_ref, index}}

  defp do_type({:var, name}, _providers), do: %Type{kind: :any, source: {:var, name}}

  defp do_type({:remote, module, function, args}, providers) when is_list(args) do
    Typespec.resolve_remote(module, function, Enum.map(args, &do_type(&1, providers)), providers)
  end

  defp do_type({:builtin, :keyword, args}, providers) do
    argument =
      case args do
        [] -> %Type{kind: :any}
        [type] -> do_type(type, providers)
        types -> %Type{kind: :any, source: {:keyword, types}}
      end

    Stdlib.keyword_type(argument)
  end

  defp do_type({:builtin, name, _args}, _providers),
    do: %Type{kind: :unsupported, source: {:builtin, name}}

  defp do_type({:dynamic, _type}, _providers), do: %Type{kind: :any, source: :dynamic}
  defp do_type({:unsupported, reason}, _providers), do: %Type{kind: :unsupported, source: reason}

  # A malformed expression from an external source must not take down the
  # compiler; the IR becomes untyped with a diagnostic-friendly source.
  defp do_type(other, _providers),
    do: %Type{kind: :unsupported, source: {:invalid_type_expr, other}}

  defp additional_type(nil, _providers), do: nil
  defp additional_type(:none, _providers), do: nil
  defp additional_type(type, providers), do: do_type(type, providers)

  defp projection([], _providers), do: %Type{kind: :unsupported, source: :intersection}

  defp projection([only], providers), do: do_type(only, providers)

  defp projection([first | rest], providers) do
    Enum.reduce_while(rest, {:ok, first}, fn variant, {:ok, acc} ->
      case Projection.intersect(acc, variant) do
        {:ok, result} -> {:cont, {:ok, result}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, result} -> do_type(result, providers)
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
