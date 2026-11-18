defmodule ToolCall.TypeExpr do
  @moduledoc """
  Source-neutral, unresolved type expressions for `ToolCall.TypeCompiler`.

  A `TypeExpr` describes type shape, local references, remote/provider
  boundaries, and value-domain annotations. It deliberately does not carry
  `ToolCall.IR.Type` wire metadata such as transforms, validators, or JSON Schema
  refs; `TypeCompiler` resolves those later.

  `:local_ref` is an intermediate index produced during local-type expansion;
  `rewrite_refs` turns it into a named `:ref`.
  """

  @type field :: {atom(), t(), boolean()}

  @type t ::
          :any
          | :none
          | {:literal, term()}
          | {:primitive, :boolean | :integer | :float | :number | :string | :atom}
          | {:integer_range, integer() | nil, integer() | nil}
          | {:enum, [term()]}
          | {:string, map()}
          | {:list, t()}
          | {:nonempty_list, t()}
          | {:tuple, [t()] | nil}
          | {:map, [field()], t() | nil}
          | {:union, [t()]}
          | {:intersection, [t()]}
          | {:negation, t()}
          | {:var, atom()}
          | {:ref, String.t()}
          | {:ref, {atom(), non_neg_integer()}, [t()]}
          | {:local_ref, non_neg_integer()}
          | {:remote, module(), atom(), [t()]}
          | {:builtin, atom(), [t()]}
          | {:dynamic, t()}
          | {:unsupported, term()}
          | {:annotated, t(), map()}

  @doc """
  Validates the shape of a type expression.

  This checks the structure a source is allowed to produce, not whether the type
  has a JSON representation. It is called at the source/compiler boundary so a
  malformed nested expression becomes an `:unsupported` IR node instead of a
  crash.
  """
  @spec validate(t()) :: :ok | {:error, String.t()}
  def validate(expression), do: validate(expression, "$")

  @primitive_kinds [:boolean, :integer, :float, :number, :string, :atom]

  defp validate(:any, _path), do: :ok
  defp validate(:none, _path), do: :ok
  defp validate({:literal, _value}, _path), do: :ok

  defp validate({:primitive, kind}, _path) when kind in @primitive_kinds, do: :ok

  defp validate({:integer_range, low, high}, path) do
    cond do
      low != nil and not is_integer(low) ->
        error(path, "integer_range low must be an integer or nil")

      high != nil and not is_integer(high) ->
        error(path, "integer_range high must be an integer or nil")

      is_integer(low) and is_integer(high) and low > high ->
        error(path, "integer_range low exceeds high")

      true ->
        :ok
    end
  end

  defp validate({:enum, values}, _path) when is_list(values), do: :ok

  defp validate({:string, metadata}, path) when is_map(metadata) do
    validate_string_metadata(metadata, path)
  end

  defp validate({:list, item}, path), do: validate(item, path <> ".item")
  defp validate({:nonempty_list, item}, path), do: validate(item, path <> ".item")
  defp validate({:tuple, nil}, _path), do: :ok

  defp validate({:tuple, items}, path) when is_list(items) do
    validate_all(items, path <> ".items")
  end

  defp validate({:map, fields, additional}, path) when is_list(fields) do
    with :ok <- validate_fields(fields, path <> ".fields") do
      validate_optional(additional, path <> ".additional")
    end
  end

  defp validate({:union, items}, path) when is_list(items),
    do: validate_all(items, path <> ".variants")

  defp validate({:intersection, items}, path) when is_list(items),
    do: validate_all(items, path <> ".variants")

  defp validate({:negation, item}, path), do: validate(item, path <> ".negation")
  defp validate({:var, name}, _path) when is_atom(name), do: :ok
  defp validate({:ref, ref}, _path) when is_binary(ref), do: :ok

  defp validate({:ref, {name, arity}, args}, path)
       when is_atom(name) and is_integer(arity) and arity >= 0 do
    validate_all(args, path <> ".args")
  end

  defp validate({:local_ref, index}, _path) when is_integer(index) and index >= 0, do: :ok

  defp validate({:remote, module, function, args}, path)
       when is_atom(module) and is_atom(function) and is_list(args) do
    validate_all(args, path <> ".args")
  end

  defp validate({:builtin, name, args}, path) when is_atom(name) and is_list(args),
    do: validate_all(args, path <> ".args")

  defp validate({:dynamic, item}, path), do: validate(item, path <> ".dynamic")
  defp validate({:unsupported, _reason}, _path), do: :ok

  defp validate({:annotated, item, metadata}, path) when is_map(metadata) do
    with :ok <- validate_string_metadata(metadata, path <> ".metadata") do
      validate(item, path <> ".type")
    end
  end

  defp validate(_other, path), do: error(path, "unknown type expression")

  defp validate_fields(fields, path) do
    fields
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn
      {{key, type, required?}, index}, :ok
      when is_atom(key) and is_boolean(required?) ->
        validate_item(type, "#{path}[#{index}]")

      {field, index}, :ok ->
        {:halt,
         error("#{path}[#{index}]", "expected {atom, TypeExpr, boolean}, got: #{inspect(field)}")}
    end)
  end

  defp validate_optional(nil, _path), do: :ok
  defp validate_optional(:none, _path), do: :ok
  defp validate_optional(type, path), do: validate(type, path)

  defp validate_all(items, path) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {item, index}, :ok ->
      validate_item(item, "#{path}[#{index}]")
    end)
  end

  defp validate_item(item, path) do
    case validate(item, path) do
      :ok -> {:cont, :ok}
      {:error, _} = error -> {:halt, error}
    end
  end

  defp validate_string_metadata(metadata, path) do
    Enum.reduce_while([:pattern, :format, :source], :ok, fn key, :ok ->
      case validate_metadata_value(Map.get(metadata, key), key, path) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_metadata_value(nil, _key, _path), do: :ok

  defp validate_metadata_value(value, :pattern, path) when is_binary(value) do
    case Regex.compile(value, "u") do
      {:ok, _regex} -> :ok
      {:error, _reason} -> error(path, "pattern must compile, got: #{inspect(value)}")
    end
  end

  defp validate_metadata_value(value, key, _path)
       when key in [:pattern, :format] and is_binary(value),
       do: :ok

  defp validate_metadata_value(value, key, path) when key in [:pattern, :format],
    do: error(path, "#{key} must be a string or nil, got: #{inspect(value)}")

  defp validate_metadata_value(value, _key, _path) when is_atom(value), do: :ok

  defp validate_metadata_value(value, key, path),
    do: error(path, "#{key} must be a string or atom, got: #{inspect(value)}")

  defp error(path, message), do: {:error, "#{path}: #{message}"}

  @doc "The empty type."
  @spec none() :: :none
  def none, do: :none

  @doc false
  @spec children(t()) :: [t()]
  def children({:list, item}), do: [item]
  def children({:nonempty_list, item}), do: [item]
  def children({:tuple, nil}), do: []
  def children({:tuple, items}) when is_list(items), do: items
  def children({:map, fields, additional}), do: Enum.map(fields, &elem(&1, 1)) ++ [additional]
  def children({:union, items}), do: items
  def children({:intersection, items}), do: items
  def children({:negation, item}), do: [item]
  def children({:ref, _key, args}), do: args
  def children({:remote, _module, _function, args}), do: args
  def children({:builtin, _name, args}), do: args
  def children({:dynamic, item}), do: [item]
  def children({:annotated, item, _meta}), do: [item]
  def children({:enum, _values}), do: []
  def children({:local_ref, _index}), do: []
  def children({:var, _name}), do: []
  def children(_node), do: []

  @doc false
  @spec put_children(t(), [t()]) :: t()
  def put_children({:map, fields, nil}, children) do
    {items, rest} = Enum.split(children, length(fields))
    fields = zip_fields(fields, items)
    if rest == [], do: {:map, fields, nil}, else: {:map, fields, List.first(rest)}
  end

  def put_children({:map, fields, additional}, children) do
    {items, rest} = Enum.split(children, length(fields))
    fields = zip_fields(fields, items)
    {:map, fields, List.first(rest, additional)}
  end

  def put_children({:tuple, nil}, _children), do: {:tuple, nil}
  def put_children({:tuple, _items}, children), do: {:tuple, children}
  def put_children({:union, _items}, children), do: {:union, children}
  def put_children({:intersection, _items}, children), do: {:intersection, children}
  def put_children({:ref, key, _args}, children), do: {:ref, key, children}

  def put_children({:remote, module, function, _args}, children),
    do: {:remote, module, function, children}

  def put_children({:builtin, name, _args}, children), do: {:builtin, name, children}
  def put_children({:annotated, _item, meta}, [item]), do: {:annotated, item, meta}

  def put_children({tag, _item}, [item]) when tag in [:list, :nonempty_list, :negation, :dynamic],
    do: {tag, item}

  def put_children(node, _children), do: node

  defp zip_fields(fields, items) do
    Enum.zip_with(fields, items, fn {key, _type, required?}, type -> {key, type, required?} end)
  end
end
