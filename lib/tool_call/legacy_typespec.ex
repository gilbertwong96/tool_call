defmodule ToolCall.LegacyTypespec do
  @moduledoc """
  Adapter around the legacy Erlang typespec APIs used by ToolCall.

  Elixir's native type signatures are still evolving. Keeping the legacy typespec APIs
  and module-attribute access here gives the current compiler one replacement
  point when typed structs or native type declarations land.
  """

  @doc false
  @spec get_attribute(module(), atom()) :: term()
  def get_attribute(module, attribute) when is_atom(module) and is_atom(attribute) do
    Module.get_attribute(module, attribute)
  end

  @doc false
  @spec fetch_types(module()) :: {:ok, list()} | :error
  def fetch_types(module) when is_atom(module) do
    Code.Typespec.fetch_types(module)
  end

  @doc false
  @spec type_to_quoted(term()) :: term()
  def type_to_quoted(type) do
    Code.Typespec.type_to_quoted(type)
  end
end
