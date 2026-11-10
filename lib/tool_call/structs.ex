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
          {:ok, %{atom() => term()}, [LocalTypes.instantiation()], field_status(), boolean()}
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
    {shape, nullable?} = split_nullable_struct(expanded)

    case shape do
      {:%, _, [^module, {:%{}, _, type_pairs}]} ->
        types = Map.new(type_pairs)
        field_pairs = pairs || type_pairs

        fields =
          for {field, _default} <- field_pairs, into: %{} do
            {field, normalize_field_ast(Map.get(types, field, {:any, [], []}))}
          end

        {:ok, fields, insts, if(truncated?, do: :truncated, else: :ok), nullable?}

      _other when is_nil(pairs) ->
        :error

      _other ->
        {:ok, any_from_pairs(pairs), [], :non_literal_t, false}
    end
  end

  # Without the captured `__struct__/0` map there is no field list to use.
  defp current_fields(_module, _status, nil, _normalize), do: :error

  defp current_fields(_module, status, pairs, _normalize) do
    status = if status == :absent, do: :ok, else: status
    {:ok, any_from_pairs(pairs), [], status, false}
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

  @type field_status :: :ok | :truncated | :parameterized_t | :non_literal_t | :no_typespec

  defp do_fields(module) do
    case fetch_types(module) do
      {:ok, entries} -> from_entries(module, entries)
      :error -> from_source(module)
    end
  rescue
    _exception -> {:ok, any_fields(module), [], :no_typespec, false}
  end

  defp from_entries(module, entries) do
    case Enum.find(entries, &match?({_kind, {:t, _body, []}}, &1)) do
      {:opaque, {:t, _body, []}} -> :opaque
      {:type, {:t, body, []}} -> type_fields(module, body)
      nil -> {:ok, any_fields(module), [], missing_t_status(entries), false}
    end
  end

  defp type_fields(module, body) do
    {:"::", _, [{:t, _, []}, type_ast]} = Code.Typespec.type_to_quoted({:t, body, []})
    from_type_ast(module, type_ast, definitions(module))
  end

  defp from_type_ast(module, type_ast, definitions) do
    definitions = Map.put(definitions, {:t, 0}, {[], {:%, [], [module, {:%{}, [], []}]}})

    {expanded, truncated?, insts} = LocalTypes.expand(type_ast, definitions)
    {shape, nullable?} = split_nullable_struct(expanded)

    case shape do
      {:%, _, [^module, {:%{}, _, pairs}]} ->
        types = Map.new(pairs)

        fields =
          for field <- struct_keys(module), into: %{} do
            {field, normalize_field_ast(Map.get(types, field, {:any, [], []}))}
          end

        {:ok, fields, insts, if(truncated?, do: :truncated, else: :ok), nullable?}

      _other ->
        {:ok, any_fields(module), [], :non_literal_t, false}
    end
  end

  # `@type t :: %__MODULE__{...} | nil` is a common way to make a struct
  # optional; unwrap the nil branch so the fields keep their types and the
  # struct stays nullable wherever it is used.
  defp split_nullable_struct({:|, _, [left, right]} = union) do
    cond do
      null_type?(left) -> {right, true}
      null_type?(right) -> {left, true}
      true -> {union, false}
    end
  end

  defp split_nullable_struct(other), do: {other, false}

  defp null_type?(nil), do: true
  defp null_type?({nil, _, _}), do: true
  defp null_type?(_other), do: false

  defp missing_t_status(entries) do
    if Enum.any?(entries, &match?({_kind, {:t, _body, [_ | _]}}, &1)),
      do: :parameterized_t,
      else: :ok
  end

  # A module compiled in memory (`Code.compile_string/1`, a Livebook cell) or
  # without debug info has no typespec chunk. When its source file is still
  # there, parse the module's `@type` declarations as a best-effort fallback:
  # fully-qualified aliases, `__MODULE__` and local types resolve; shorthand
  # aliases from `alias` directives degrade to `{}`.
  defp from_source(module) do
    with {:ok, path} <- source_path(module),
         {:ok, source} <- File.read(path),
         {:ok, ast} <- Code.string_to_quoted(source),
         {:ok, body, inherited_aliases} <- find_module(ast, module) do
      from_source_body(module, body, inherited_aliases)
    else
      _other -> {:ok, any_fields(module), [], :no_typespec, false}
    end
  rescue
    _exception -> {:ok, any_fields(module), [], :no_typespec, false}
  end

  defp source_path(module) do
    case module.module_info(:compile)[:source] do
      source when is_list(source) ->
        path = List.to_string(source)
        if path != "nofile" and File.regular?(path), do: {:ok, path}, else: :error

      _other ->
        :error
    end
  rescue
    _exception -> :error
  end

  defp find_module(ast, target, prefix \\ nil, inherited_aliases \\ %{})

  defp find_module({:defmodule, _meta, [name_ast, [do: body]]}, target, prefix, inherited_aliases) do
    case module_name(name_ast, prefix) do
      ^target -> {:ok, body, inherited_aliases}
      nil -> :error
      module -> find_in(source_statements(body), target, module, inherited_aliases)
    end
  end

  defp find_module({:__block__, _meta, statements}, target, prefix, inherited_aliases) do
    find_in(statements, target, prefix, inherited_aliases)
  end

  defp find_module(_ast, _target, _prefix, _inherited_aliases) do
    :error
  end

  defp find_in(statements, target, prefix, inherited_aliases) when is_list(statements) do
    statements
    |> Enum.reduce_while({inherited_aliases, :error}, &find_step(&1, &2, target, prefix))
    |> find_result()
  end

  defp find_in(_other, _target, _prefix, _inherited_aliases) do
    :error
  end

  defp find_step(statement, {aliases, _error}, target, prefix) do
    case find_module(statement, target, prefix, aliases) do
      {:ok, body, inherited_aliases} -> {:halt, {:ok, body, inherited_aliases}}
      :error -> {:cont, {put_statement_aliases(aliases, statement, prefix), :error}}
    end
  end

  defp find_result({:ok, body, inherited_aliases}) do
    {:ok, body, inherited_aliases}
  end

  defp find_result({_aliases, :error}) do
    :error
  end

  defp module_name({:__aliases__, _meta, [{:__MODULE__, _mod_meta, _context} | rest]}, prefix)
       when is_atom(prefix) do
    Module.concat([prefix | rest])
  end

  defp module_name({:__aliases__, _meta, [{:__MODULE__, _mod_meta, _context} | _rest]}, nil) do
    nil
  end

  defp module_name({:__aliases__, _meta, parts}, nil) do
    Module.concat(parts)
  end

  defp module_name({:__aliases__, _meta, parts}, prefix), do: Module.concat([prefix | parts])
  defp module_name(atom, _prefix) when is_atom(atom), do: atom
  defp module_name(_other, _prefix), do: nil

  defp from_source_body(module, body, inherited_aliases) do
    entries = source_entries(body, module, inherited_aliases)
    definitions = Map.new(entries, fn {key, {params, _kind, type}} -> {key, {params, type}} end)

    case Enum.find(entries, &match?({{:t, 0}, _value}, &1)) do
      {{:t, 0}, {_params, :opaque, _type}} -> :opaque
      {{:t, 0}, {_params, _kind, type}} -> from_type_ast(module, type, definitions)
      nil -> from_source_missing_t(module, entries)
    end
  end

  defp from_source_missing_t(module, entries) do
    if parameterized_t?(entries) do
      {:ok, any_fields(module), [], :parameterized_t, false}
    else
      {:ok, any_fields(module), [], :ok, false}
    end
  end

  defp parameterized_t?(entries) do
    Enum.any?(entries, fn
      {{:t, arity}, _value} -> arity > 0
      _entry -> false
    end)
  end

  defp source_entries(body, module, initial_aliases) do
    body
    |> source_statements()
    |> Enum.reduce({initial_aliases, []}, fn statement, {aliases, entries} ->
      {put_statement_aliases(aliases, statement, module),
       source_type_entry(statement, module, aliases) ++ entries}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp put_statement_aliases(
         acc,
         {:alias, _meta, [{:__aliases__, _alias_meta, parts} | rest]},
         module
       ) do
    put_source_alias(acc, rewrite_alias_parts(parts, module), rest)
  end

  defp put_statement_aliases(
         acc,
         {:alias, _meta, [{{:., _, [base_ast, :{}]}, _, aliases}]},
         module
       ) do
    case alias_base(base_ast, module) do
      nil ->
        acc

      base ->
        Enum.reduce(aliases, acc, fn
          {:__aliases__, _, parts}, acc ->
            put_source_alias(acc, base ++ rewrite_alias_parts(parts, module), [])

          _other, acc ->
            acc
        end)
    end
  end

  defp put_statement_aliases(acc, _statement, _module) do
    acc
  end

  defp rewrite_alias_parts(parts, module) do
    Enum.map(parts, fn
      {:__MODULE__, _meta, _context} -> module
      other -> other
    end)
  end

  defp alias_base({:__aliases__, _meta, parts}, module) do
    rewrite_alias_parts(parts, module)
  end

  defp alias_base({:__MODULE__, _meta, _context}, module) do
    [module]
  end

  defp alias_base(_other, _module) do
    nil
  end

  defp put_source_alias(acc, [head | _rest] = parts, rest_opts) when is_atom(head) do
    target = Module.concat(parts)
    Map.put(acc, alias_key(parts, rest_opts), target)
  rescue
    _exception -> acc
  end

  defp put_source_alias(acc, _parts, _rest) do
    acc
  end

  defp alias_key(parts, [opts | _rest]) when is_list(opts) do
    case Keyword.get(opts, :as) do
      {:__aliases__, _meta, as_parts} -> List.last(as_parts) || List.last(parts)
      _other -> List.last(parts)
    end
  end

  defp alias_key(parts, _rest) do
    List.last(parts)
  end

  defp source_statements({:__block__, _meta, statements}), do: statements
  defp source_statements(other), do: [other]

  defp source_type_entry(
         {:@, _meta,
          [{kind, _kind_meta, [{:"::", _op_meta, [{name, _name_meta, params}, type]}]}]},
         module,
         aliases
       )
       when kind in [:type, :opaque, :typep] and is_atom(name) do
    params = params || []
    type = rewrite_source_type(type, module, aliases)
    [{{name, length(params)}, {params, kind, type}}]
  end

  defp source_type_entry(_other, _module, _aliases) do
    []
  end

  defp rewrite_source_type(ast, module, aliases) do
    ast
    |> Macro.prewalk(fn
      {:__MODULE__, _meta, _context} -> module
      other -> other
    end)
    |> Macro.prewalk(&rewrite_source_alias(&1, aliases))
  end

  defp rewrite_source_alias({:__aliases__, _meta, [head | rest]} = alias_node, aliases)
       when is_atom(head) do
    case Map.fetch(aliases, head) do
      {:ok, target} -> concat_source_alias([target | rest], alias_node)
      :error -> concat_source_alias([head | rest], alias_node)
    end
  end

  defp rewrite_source_alias(other, _aliases) do
    other
  end

  defp concat_source_alias(parts, alias_node) do
    if Enum.all?(parts, &is_atom/1) do
      Module.concat(parts)
    else
      alias_node
    end
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
