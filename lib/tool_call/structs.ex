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
    Code.ensure_compiled(module) == {:module, module} and
      function_exported?(module, :__struct__, 0)
  end

  @spec fields(module()) ::
          {:ok, %{atom() => term()}, [LocalTypes.instantiation()], field_status()}
          | :opaque
          | :error
  def fields(module) when is_atom(module) do
    if struct?(module), do: do_fields(module), else: :error
  end

  @spec enforced_keys(module()) :: {:ok, [atom()]} | :error
  def enforced_keys(module) when is_atom(module) do
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

  defp normalize_field_ast(:any), do: {:any, [], []}
  defp normalize_field_ast({name, _, []}) when name in [:term, :any], do: {:any, [], []}
  defp normalize_field_ast(ast), do: ast
end
