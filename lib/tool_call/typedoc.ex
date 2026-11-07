defmodule ToolCall.Typedoc do
  @moduledoc false
  # Recovers docs-visible `@typedoc` text from the EEP-48 `Docs` chunk after
  # the defining module has closed, then uses it as a fallback parameter
  # description. Elixir discards `@typep` typedocs at definition time, so they
  # never appear in the chunk and never match.

  # `apply/3` is part of this module's interface, so it shadows Kernel.apply/3.
  import Kernel, except: [apply: 3]

  alias ToolCall.IR.{Param, Tool}

  @type type_key :: {atom(), non_neg_integer()}
  @type typedocs :: %{type_key() => String.t()}
  @type typedoc_keys :: %{{term(), term()} => [type_key()]}
  @type bytecode_error :: :missing_docs_chunk | :corrupt_docs_chunk | :unreadable_beam

  @spec from_bytecode(binary()) :: typedocs()
  def from_bytecode(bytecode) when is_binary(bytecode) do
    case from_bytecode_result(bytecode) do
      {:ok, typedocs} -> typedocs
      {:error, _reason} -> %{}
    end
  end

  # Phase two distinguishes an absent Docs chunk from a chunk that cannot be
  # trusted: no docs is expected when the compiler option is disabled, while a
  # corrupt chunk means the beam should not be reused.
  @spec from_bytecode_result(binary()) :: {:ok, typedocs()} | {:error, bytecode_error()}
  def from_bytecode_result(bytecode) when is_binary(bytecode) do
    case :beam_lib.chunks(bytecode, [~c"Docs"]) do
      {:ok, {_module, [{~c"Docs", chunk}]}} -> decode(chunk)
      {:error, :beam_lib, {:missing_chunk, _file, ~c"Docs"}} -> {:error, :missing_docs_chunk}
      _other -> {:error, :unreadable_beam}
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

  @spec keys(term(), map()) :: [type_key()]
  def keys(ast, definitions) when is_map(definitions) do
    ast
    |> unwrap_nullable()
    |> collect_keys(definitions, [])
  end

  @spec apply([Tool.t()], typedoc_keys(), typedocs()) :: [Tool.t()]
  def apply(tools, typedoc_keys, typedocs) do
    Enum.map(tools, fn %Tool{params: params} = tool ->
      params = Enum.map(params, &apply_param(&1, tool.name, typedoc_keys, typedocs))
      %{tool | params: params}
    end)
  end

  defp decode(chunk) do
    case :erlang.binary_to_term(chunk) do
      {:docs_v1, _annotation, _language, _format, _module_doc, _metadata, docs} = term
      when is_list(docs) ->
        {:ok, from_docs(term)}

      _other ->
        {:error, :corrupt_docs_chunk}
    end
  rescue
    _exception -> {:error, :corrupt_docs_chunk}
  end

  defp doc_text(doc) when is_map(doc) do
    case Map.fetch(doc, "en") do
      {:ok, text} when is_binary(text) ->
        nonempty_text(text) || first_language_text(doc)

      _other ->
        first_language_text(doc)
    end
  end

  defp doc_text(text) when is_binary(text), do: nonempty_text(text)
  defp doc_text(_doc), do: nil

  defp first_language_text(doc) do
    doc
    |> Enum.sort_by(fn {language, _text} -> language end)
    |> Enum.find_value(fn {_language, text} -> nonempty_text(text) end)
  end

  defp collect_keys({name, _meta, args}, definitions, seen)
       when is_atom(name) and is_list(args) do
    key = {name, length(args)}

    if Map.has_key?(definitions, key) and key not in seen do
      {params, body} = Map.fetch!(definitions, key)

      next =
        body
        |> ToolCall.LocalTypes.substitute(params, args)
        |> unwrap_nullable()

      [key | collect_keys(next, definitions, [key | seen])]
    else
      []
    end
  end

  defp collect_keys(_ast, _definitions, _seen), do: []

  defp unwrap_nullable({:|, _meta, [left, nil]}), do: left
  defp unwrap_nullable({:|, _meta, [nil, right]}), do: right
  defp unwrap_nullable(ast), do: ast

  defp apply_param(%Param{description: nil, name: name} = param, tool_name, keys, docs) do
    with key when not is_nil(key) <- Map.get(keys, {tool_name, name}),
         text when is_binary(text) and text != "" <- first_doc(key, docs) do
      %{param | description: text}
    else
      _other -> param
    end
  end

  defp apply_param(param, _tool_name, _keys, _docs), do: param

  defp first_doc(keys, docs) when is_list(keys) do
    Enum.find_value(keys, fn key -> nonempty_text(Map.get(docs, key)) end)
  end

  defp first_doc(key, docs), do: nonempty_text(Map.get(docs, key))

  defp nonempty_text(text) when is_binary(text) do
    if String.trim(text) == "", do: nil, else: text
  end

  defp nonempty_text(_text), do: nil
end
