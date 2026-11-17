# reach:disable-for-this-file string_building
# Compile-time diagnostic and $defs names are short lived; iolists would
# obscure the messages without a runtime benefit.
defmodule ToolCall.LocalTypes do
  @moduledoc """
  AST-facing facade for local type expansion.

  The shared expansion algorithm lives in `ToolCall.LocalTypeAlgorithm`; this
  module supplies module attributes and the legacy AST adapter.
  """

  # AST-facing facade for local type expansion. The shared algorithm lives in
  # ToolCall.LocalTypeAlgorithm; this module only supplies module attributes and
  # the legacy AST adapter.

  alias ToolCall.{LegacyTypespec, LocalTypeAlgorithm}
  alias ToolCall.LocalTypeAlgorithm.{AstAdapter, RefName}

  @type instantiation :: LocalTypeAlgorithm.instantiation()

  @doc """
  Expands local type references in `ast`.

  See `ToolCall.LocalTypeAlgorithm.expand/4`. The returned instantiation refs use
  the AST adapter's reserved `:tool_call_ref` syntax.
  """
  @spec expand(term(), module() | map(), keyword()) ::
          {term(), boolean(), [instantiation()]}
  def expand(ast, module_or_definitions, opts \\ [])

  def expand(ast, module, opts) when is_atom(module),
    do: expand(ast, definitions(module), opts)

  def expand(ast, definitions, opts) when is_map(definitions) and is_list(opts) do
    LocalTypeAlgorithm.expand(ast, definitions, AstAdapter, opts)
  end

  @doc false
  @spec definitions(module()) :: map()
  def definitions(module) do
    for attribute <- [:type, :typep, :opaque],
        {_kind, {:"::", _, [{name, _, params}, body]}, _location} <-
          List.wrap(LegacyTypespec.get_attribute(module, attribute)),
        is_atom(name),
        into: %{} do
      params = List.wrap(params)
      {{name, length(params)}, {params, body}}
    end
  end

  @doc false
  @spec cyclic_keys(map()) :: MapSet.t({atom(), non_neg_integer()})
  def cyclic_keys(definitions), do: LocalTypeAlgorithm.cyclic_keys(definitions, AstAdapter)

  @doc false
  @spec max_defs() :: pos_integer()
  def max_defs, do: LocalTypeAlgorithm.max_defs()

  @doc false
  @spec rewrite_refs(term(), %{non_neg_integer() => String.t()}) :: term()
  def rewrite_refs(ast, names), do: AstAdapter.rewrite_refs(ast, names)

  @doc false
  @spec name({atom(), non_neg_integer()}, [term()]) :: String.t()
  def name(key, args), do: RefName.from_ast(key, args)

  @doc false
  def substitute(body, params, args), do: AstAdapter.substitute(body, params, args)

  @doc false
  @spec var_name(term()) :: term()
  def var_name(node), do: AstAdapter.var_name(node)
end
