defmodule ToolCall.Typedoc do
  @moduledoc false
  # Recovers docs-visible `@typedoc` text from the EEP-48 `Docs` chunk after
  # the defining module has closed, then uses it as a fallback parameter
  # description. `@typep` typedocs are hidden in the chunk, so they never match.

  # `apply/3` is part of this module's interface, so it shadows Kernel.apply/3.
  import Kernel, except: [apply: 3]

  alias ToolCall.IR.{Param, Tool}

  @type type_key :: {atom(), non_neg_integer()}
  @type typedocs :: %{type_key() => String.t()}
  @type typedoc_keys :: %{{term(), term()} => type_key()}

  @spec from_bytecode(binary()) :: typedocs()
  def from_bytecode(bytecode) when is_binary(bytecode) do
    case :beam_lib.chunks(bytecode, [~c"Docs"]) do
      {:ok, {_module, [{~c"Docs", chunk}]}} -> decode(chunk)
      _other -> %{}
    end
  end

  @spec from_docs(term()) :: typedocs()
  def from_docs({:docs_v1, _annotation, _language, _format, _module_doc, _metadata, docs})
      when is_list(docs) do
    for {{:type, name, arity}, _annotation, _signature, doc, _metadata} <- docs,
        is_atom(name),
        is_integer(arity) and arity >= 0,
        text = doc_text(doc),
        is_binary(text),
        into: %{} do
      {{name, arity}, text}
    end
  end

  def from_docs(_docs), do: %{}

  @spec key(term(), map()) :: type_key() | nil
  def key(ast, definitions) when is_map(definitions) do
    case unwrap_nullable(ast) do
      {name, _meta, args} when is_atom(name) and is_list(args) ->
        type_key = {name, length(args)}
        if Map.has_key?(definitions, type_key), do: type_key

      _other ->
        nil
    end
  end

  @spec apply([Tool.t()], typedoc_keys(), typedocs()) :: [Tool.t()]
  def apply(tools, typedoc_keys, typedocs) do
    Enum.map(tools, fn %Tool{params: params} = tool ->
      params = Enum.map(params, &apply_param(&1, tool.name, typedoc_keys, typedocs))
      %{tool | params: params}
    end)
  end

  defp decode(chunk) do
    chunk
    |> :erlang.binary_to_term()
    |> from_docs()
  rescue
    ArgumentError -> %{}
  end

  defp doc_text(%{"en" => text}) when is_binary(text), do: text

  defp doc_text(doc) when is_map(doc) do
    doc
    |> Enum.sort_by(fn {language, _text} -> language end)
    |> Enum.find_value(fn
      {_language, text} when is_binary(text) -> text
      _other -> nil
    end)
  end

  defp doc_text(text) when is_binary(text), do: text
  defp doc_text(_doc), do: nil

  defp unwrap_nullable({:|, _meta, [left, nil]}), do: left
  defp unwrap_nullable({:|, _meta, [nil, right]}), do: right
  defp unwrap_nullable(ast), do: ast

  defp apply_param(%Param{description: nil, name: name} = param, tool_name, keys, docs) do
    with type_key when not is_nil(type_key) <- Map.get(keys, {tool_name, name}),
         text when is_binary(text) and text != "" <- Map.get(docs, type_key) do
      %{param | description: text}
    else
      _other -> param
    end
  end

  defp apply_param(param, _tool_name, _keys, _docs), do: param
end
