defmodule ToolCall.Structs do
  @moduledoc false
  # Compile-time introspection of a compiled struct module.
  #
  # Field names come from `__struct__/0`. Field types come from the module's
  # public `@type t`, after expanding the module's own local types; a
  # self-reference to `t/0` is replaced by `%__MODULE__{}` so it becomes a
  # struct marker instead of a local-type ref. `@enforce_keys` is not readable
  # for a compiled module: `Module.get_attribute/2` raises, and neither
  # `__info__(:attributes)` nor the docs chunk carries it. The only signal is
  # `__struct__/1` raising on a missing key, so `enforced_keys/1` removes one
  # field at a time and keeps the fields whose removal raises.

  alias ToolCall.LocalTypes

  @spec struct?(module()) :: boolean()
  def struct?(module) when is_atom(module) do
    case Code.ensure_compiled(module) do
      {:module, ^module} -> function_exported?(module, :__struct__, 0)
      _other -> open_struct?(module)
    end
  end

  defp open_struct?(module) do
    Module.open?(module) and {:__struct__, 1} in Module.definitions_in(module, :def)
  rescue
    _exception -> false
  end

  @spec fields(module(), keyword()) ::
          {:ok, %{atom() => term()}, [LocalTypes.instantiation()], field_status()}
          | :opaque
          | :error
  def fields(module, opts \\ []) when is_atom(module) do
    current = Keyword.get(opts, :current)

    cond do
      current != nil and module == current ->
        current_fields(module, Keyword.get(opts, :normalize, & &1))

      struct?(module) ->
        do_fields(module)

      true ->
        :error
    end
  end

  @spec enforced_keys(module(), keyword()) :: {:ok, [atom()]} | :error
  def enforced_keys(module, opts \\ []) when is_atom(module) do
    current = Keyword.get(opts, :current)

    if current != nil and module == current do
      current_enforced_keys(module)
    else
      probe_enforced_keys(module)
    end
  end

  defp probe_enforced_keys(module) do
    defaults = module.__struct__() |> Map.delete(:__struct__)
    keys = defaults |> Map.keys() |> Enum.reject(&(&1 == :__exception__)) |> Enum.sort()

    enforced =
      Enum.filter(keys, fn key ->
        try do
          module.__struct__(Enum.map(keys -- [key], &{&1, Map.fetch!(defaults, &1)}))
          false
        rescue
          ArgumentError -> true
        end
      end)

    {:ok, enforced}
  rescue
    _exception -> :error
  end

  defp current_enforced_keys(module) do
    keys =
      module
      |> Module.get_attribute(:enforce_keys)
      |> List.wrap()
      |> Enum.reject(&(&1 == :__exception__))
      |> Enum.sort()

    {:ok, keys}
  rescue
    _exception -> :error
  end

  defp current_fields(module, normalize) do
    case current_type(module) do
      :opaque ->
        :opaque

      type ->
        current_fields(
          module,
          type,
          Module.get_attribute(module, :tool_call_struct_fields),
          normalize
        )
    end
  end

  defp current_fields(module, {:ok, body}, pairs, normalize) do
    definitions =
      module
      |> LocalTypes.definitions()
      |> Map.new(fn {key, {params, type}} -> {key, {params, normalize.(type)}} end)
      |> Map.put({:t, 0}, {[], {:%, [], [module, {:%{}, [], []}]}})

    {expanded, truncated?, insts} = LocalTypes.expand(normalize.(body), definitions)

    case expanded do
      {:%, _, [^module, {:%{}, _, type_pairs}]} ->
        types = Map.new(type_pairs)
        field_pairs = pairs || type_pairs

        fields =
          for {field, _default} <- field_pairs, into: %{} do
            {field, normalize_field_ast(Map.get(types, field, {:any, [], []}))}
          end

        {:ok, fields, insts, if(truncated?, do: :truncated, else: :ok)}

      _other when is_nil(pairs) ->
        :error

      _other ->
        {:ok, any_from_pairs(pairs), [], :non_literal_t}
    end
  end

  # Without the captured `__struct__/0` map there is no field list to use.
  defp current_fields(_module, _status, nil, _normalize), do: :error

  defp current_fields(_module, status, pairs, _normalize) do
    status = if status == :absent, do: :ok, else: status
    {:ok, any_from_pairs(pairs), [], status}
  end

  defp any_from_pairs(pairs) do
    Map.new(pairs, fn {field, _default} -> {field, {:any, [], []}} end)
  end

  defp current_type(module) do
    types = List.wrap(Module.get_attribute(module, :type))
    opaques = List.wrap(Module.get_attribute(module, :opaque))

    t0 = fn
      {:type, {:"::", _, [{:t, _, params}, body]}, _} when params in [nil, []] -> {:ok, body}
      _entry -> nil
    end

    parameterized? =
      Enum.any?(types, fn
        {:type, {:"::", _, [{:t, _, params}, _]}, _} -> is_list(params) and params != []
        _entry -> false
      end)

    opaque? =
      Enum.any?(opaques, fn
        {:opaque, {:"::", _, [{:t, _, params}, _]}, _} -> params in [nil, []]
        _entry -> false
      end)

    cond do
      opaque? -> :opaque
      found = Enum.find_value(types, t0) -> found
      parameterized? -> :parameterized_t
      true -> :absent
    end
  end

  @spec name(module()) :: String.t()
  def name(module) when is_atom(module) do
    module |> Module.split() |> Enum.join("_") |> String.slice(0, 64)
  end

  @type field_status :: :ok | :truncated | :parameterized_t | :non_literal_t

  defp do_fields(module) do
    case fetch_types(module) do
      {:ok, entries} -> from_entries(module, entries)
      :error -> {:ok, any_fields(module), [], :ok}
    end
  rescue
    _exception -> {:ok, any_fields(module), [], :ok}
  end

  defp from_entries(module, entries) do
    case Enum.find(entries, &match?({_kind, {:t, _body, []}}, &1)) do
      {:opaque, {:t, _body, []}} -> :opaque
      {:type, {:t, body, []}} -> type_fields(module, body)
      nil -> {:ok, any_fields(module), [], missing_t_status(entries)}
    end
  end

  defp type_fields(module, body) do
    {:"::", _, [{:t, _, []}, type_ast]} = Code.Typespec.type_to_quoted({:t, body, []})

    definitions =
      module
      |> definitions()
      |> Map.put({:t, 0}, {[], {:%, [], [module, {:%{}, [], []}]}})

    {expanded, truncated?, insts} = LocalTypes.expand(type_ast, definitions)

    case expanded do
      {:%, _, [^module, {:%{}, _, pairs}]} ->
        types = Map.new(pairs)

        fields =
          for field <- struct_keys(module), into: %{} do
            {field, normalize_field_ast(Map.get(types, field, {:any, [], []}))}
          end

        {:ok, fields, insts, if(truncated?, do: :truncated, else: :ok)}

      _other ->
        {:ok, any_fields(module), [], :non_literal_t}
    end
  end

  defp missing_t_status(entries) do
    if Enum.any?(entries, &match?({_kind, {:t, _body, [_ | _]}}, &1)),
      do: :parameterized_t,
      else: :ok
  end

  defp definitions(module) do
    case fetch_types(module) do
      {:ok, entries} -> Enum.reduce(entries, %{}, &definition_entry/2)
      :error -> %{}
    end
  end

  defp definition_entry({:type, {name, body, params}}, acc) do
    case Code.Typespec.type_to_quoted({name, body, params}) do
      {:"::", _, [{^name, _, vars}, type_ast]} ->
        Map.put(acc, {name, length(params)}, {vars, type_ast})

      _other ->
        acc
    end
  end

  defp definition_entry(_entry, acc), do: acc

  defp fetch_types(module), do: Code.Typespec.fetch_types(module)

  # `__exception__` is a sentinel that `defexception` sets to true; it is not a
  # payload field and dispatch must leave it at its default.
  defp struct_keys(module) do
    module.__struct__() |> Map.delete(:__struct__) |> Map.delete(:__exception__) |> Map.keys()
  end

  defp any_fields(module) do
    Map.new(struct_keys(module), &{&1, {:any, [], []}})
  end

  defp normalize_field_ast({name, _, []}) when name in [:term, :any], do: {:any, [], []}
  defp normalize_field_ast(ast), do: ast
end
