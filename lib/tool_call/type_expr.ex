defmodule ToolCall.TypeExpr do
  @moduledoc """
  Source-neutral, unresolved type expressions for `ToolCall.TypeCompiler`.

  A `TypeExpr` describes type shape, local references, remote/provider
  boundaries, and value-domain annotations. It deliberately does not carry
  `ToolCall.IR.Type` wire metadata such as transforms, validators, or JSON Schema
  refs; `TypeCompiler` resolves those later.

  A parameterized local reference keeps its source AST arguments as provenance
  so `$defs` names stay identical to the typespec-AST expansion. `:local_ref`
  is an intermediate index produced during expansion; `rewrite_refs` turns it
  into a named `:ref`.
  """

  @type field :: {atom(), t(), boolean()}

  @type t ::
          :any
          | :none
          | {:literal, term()}
          | {:primitive, :boolean | :integer | :float | :number | :string | :atom}
          | {:integer_range, integer(), integer()}
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
          | {:ref, {atom(), non_neg_integer()}, [t()], [term()]}
          | {:local_ref, non_neg_integer()}
          | {:remote, module(), atom(), [t()]}
          | {:builtin, atom(), [t()]}
          | {:dynamic, t()}
          | {:unsupported, term()}
          | {:annotated, t(), map()}

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
  def children({:ref, _key, args, _source}), do: args
  def children({:remote, _module, _function, args}), do: args
  def children({:builtin, _name, args}), do: args
  def children({:dynamic, item}), do: [item]
  def children({:annotated, item, _meta}), do: [item]
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
  def put_children({:ref, key, _args, source}, children), do: {:ref, key, children, source}

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
