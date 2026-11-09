defmodule ToolCall.Structs.Resolve do
  @moduledoc false
  # Turns the `:struct` markers left by `ToolCall.Typespec` into closed objects.
  #
  # Discovery walks the parameters and the existing `defs` bodies, resolves each
  # struct module once, and caches its field IR. Cyclicity is decided statically
  # over that graph: a module that can reach itself becomes one `$defs` entry,
  # and every occurrence of it — including the parameter that starts the cycle —
  # is a `:ref`. Non-cyclic modules are inlined as objects.
  #
  # The cache breaks the recursion: fields are read once per module, and the
  # build pass never needs to re-enter `Structs.fields/1`. A cyclic module's
  # definition is built once, with a `:building` placeholder so a sibling in the
  # cycle gets a ref instead of recursing.

  alias ToolCall.IR.{Field, Param, Tool, Type}
  alias ToolCall.{LocalTypes, Structs, Typespec}

  @spec run(Tool.t(), [module()], map()) :: {Tool.t(), [String.t()], map()}
  def run(%Tool{} = tool, providers, raw \\ %{}, normalize \\ & &1) do
    existing = MapSet.new(Map.keys(tool.defs || %{}))

    state = %{
      cache: %{},
      raw: raw,
      current: tool.module,
      defs: %{},
      warnings: [],
      inst_names: %{},
      existing: existing
    }

    roots = Enum.map(tool.params, & &1.type) ++ Map.values(tool.defs || %{}) ++ [tool.result]
    state = Enum.reduce(roots, state, &collect_type(&1, providers, &2, normalize))

    ctx = %{
      cache: state.cache,
      cyclic: cyclic_modules(state.cache),
      struct_defs: %{},
      struct_names: %{},
      existing: MapSet.union(existing, MapSet.new(Map.keys(state.defs)))
    }

    {params, ctx} = Enum.map_reduce(tool.params, ctx, &build_param/2)
    {result, ctx} = build_type(tool.result, ctx)

    {defs, ctx} =
      tool.defs
      |> Map.merge(state.defs)
      |> Enum.reduce({%{}, ctx}, fn {name, type}, {acc, ctx} ->
        {type, ctx} = build_type(type, ctx)
        {Map.put(acc, name, type), ctx}
      end)

    defs = Map.merge(defs, ctx.struct_defs)

    {%{tool | params: params, defs: defs, result: result}, Enum.reverse(state.warnings),
     state.raw}
  end

  # --- discovery ------------------------------------------------------------

  defp collect_type(%Type{kind: :struct, struct: module}, providers, state, normalize) do
    if Map.has_key?(state.cache, module),
      do: state,
      else: collect_struct(module, providers, state, normalize)
  end

  defp collect_type(%Type{kind: :object} = type, providers, state, normalize) do
    state = collect_types(type.fields || [], providers, state, & &1.type, normalize)
    collect_type(type.additional, providers, state, normalize)
  end

  defp collect_type(%Type{kind: :array} = type, providers, state, normalize),
    do: collect_type(type.items, providers, state, normalize)

  defp collect_type(%Type{kind: :tuple} = type, providers, state, normalize),
    do: collect_types(type.items || [], providers, state, & &1, normalize)

  defp collect_type(%Type{kind: :union} = type, providers, state, normalize),
    do: collect_types(type.variants || [], providers, state, & &1, normalize)

  defp collect_type(_type, _providers, state, _normalize), do: state

  defp collect_types(items, providers, state, to_type, normalize) do
    Enum.reduce(items, state, fn item, st ->
      collect_type(to_type.(item), providers, st, normalize)
    end)
  end

  defp collect_struct(module, providers, state, normalize) do
    {raw, state} =
      case Map.fetch(state.raw, module) do
        {:ok, raw} ->
          {raw, state}

        :error ->
          raw = introspect(module, state.current, normalize)
          state = %{state | raw: Map.put(state.raw, module, raw)}
          {raw, warn_introspection(module, raw, state)}
      end

    install_struct(module, raw, providers, state, normalize)
  end

  # Reading the beam, probing @enforce_keys and warning about the result are
  # per-module costs; a module with twenty tools should pay them once, not
  # twenty times.
  defp introspect(module, current, normalize) do
    case Structs.fields(module, current: current, normalize: normalize) do
      :opaque ->
        :opaque

      :error ->
        :error

      {:ok, field_asts, insts, status} ->
        probe =
          case Structs.enforced_keys(module, current: current) do
            {:ok, keys} -> {:ok, MapSet.new(keys)}
            :error -> :error
          end

        {:ok, %{field_asts: field_asts, insts: insts, status: status, probe: probe}}
    end
  end

  defp warn_introspection(module, :opaque, state) do
    add_warning(
      state,
      "#{inspect(module)}.t() is @opaque; its fields are hidden and the type is treated as {}"
    )
  end

  defp warn_introspection(_module, :error, state), do: state

  defp warn_introspection(module, {:ok, %{status: status, probe: probe}}, state) do
    state = maybe_warn_struct_type(module, status, state)

    case probe do
      {:ok, _keys} ->
        state

      :error ->
        add_warning(
          state,
          "could not determine @enforce_keys for #{inspect(module)}; every field is optional"
        )
    end
  end

  defp install_struct(module, :opaque, _providers, state, _normalize),
    do: put_cache(state, module, :opaque)

  defp install_struct(module, :error, _providers, state, _normalize),
    do: put_cache(state, module, :error)

  defp install_struct(module, {:ok, raw}, providers, state, normalize) do
    %{field_asts: field_asts, insts: insts, probe: probe} = raw

    required =
      case probe do
        {:ok, keys} -> keys
        :error -> MapSet.new()
      end

    {names, state} = assign_inst_names(module, insts, state)

    {defs, inst_types} =
      insts
      |> Enum.with_index()
      |> Enum.reduce({state.defs, []}, fn {inst, index}, {defs, types} ->
        name = Map.fetch!(names, index)
        type = Typespec.to_type(rewrite(inst.body, names), providers)
        {Map.put_new(defs, name, type), [type | types]}
      end)

    fields =
      Enum.map(field_asts, fn {field, ast} ->
        {field, Typespec.to_type(rewrite(ast, names), providers)}
      end)

    state = %{
      state
      | defs: defs,
        cache: Map.put(state.cache, module, %{fields: fields, required: required})
    }

    state =
      Enum.reduce(fields, state, fn {_field, type}, st ->
        collect_type(type, providers, st, normalize)
      end)

    Enum.reduce(inst_types, state, &collect_type(&1, providers, &2, normalize))
  end

  defp rewrite(ast, names), do: LocalTypes.rewrite_refs(ast, names)

  defp maybe_warn_struct_type(module, :truncated, state) do
    add_warning(
      state,
      "#{inspect(module)}'s @type t hit the type expansion budget; some fields are treated as {}"
    )
  end

  defp maybe_warn_struct_type(module, :parameterized_t, state) do
    add_warning(
      state,
      "#{inspect(module)} declares only a parameterized @type t/N; field extraction reads " <>
        "t/0, so every field is treated as {}"
    )
  end

  defp maybe_warn_struct_type(module, :non_literal_t, state) do
    add_warning(
      state,
      "#{inspect(module)}.t/0 is not a %__MODULE__{} literal; every field is treated as {}"
    )
  end

  defp maybe_warn_struct_type(_module, :ok, state), do: state

  defp assign_inst_names(module, insts, state) do
    {names, state} =
      insts
      |> Enum.with_index()
      |> Enum.map_reduce(state, fn {inst, index}, state ->
        key = {module, inst.key, inst.args}

        case Map.fetch(state.inst_names, key) do
          {:ok, name} ->
            {{index, name}, state}

          :error ->
            base = Structs.name(module) <> "_" <> LocalTypes.name(inst.key, inst.args)
            name = unique_inst_name(base, state, 1)
            {{index, name}, %{state | inst_names: Map.put(state.inst_names, key, name)}}
        end
      end)

    {Map.new(names), state}
  end

  defp unique_inst_name(base, state, counter) do
    candidate = if counter == 1, do: base, else: "#{base}_#{counter}"

    if MapSet.member?(state.existing, candidate) or
         Enum.any?(state.inst_names, fn {_key, name} -> name == candidate end),
       do: unique_inst_name(base, state, counter + 1),
       else: candidate
  end

  defp put_cache(state, module, value), do: %{state | cache: Map.put(state.cache, module, value)}

  defp add_warning(state, message), do: %{state | warnings: [message | state.warnings]}

  # --- cyclicity ------------------------------------------------------------

  defp cyclic_modules(cache) do
    edges =
      Map.new(cache, fn
        {module, %{fields: fields}} -> {module, struct_markers(fields)}
        {module, _other} -> {module, MapSet.new()}
      end)

    ToolCall.Graph.cyclic_keys(edges)
  end

  defp struct_markers(fields) do
    fields
    |> Enum.flat_map(fn {_name, type} -> markers(type) end)
    |> MapSet.new()
  end

  defp markers(%Type{kind: :struct, struct: module}), do: [module]
  defp markers(%Type{kind: :array, items: items}), do: markers(items)
  defp markers(%Type{kind: :tuple, items: items}), do: Enum.flat_map(items || [], &markers/1)

  defp markers(%Type{kind: :union, variants: variants}),
    do: Enum.flat_map(variants || [], &markers/1)

  defp markers(%Type{kind: :object, fields: fields, additional: additional}) do
    Enum.flat_map(fields || [], &markers(&1.type)) ++ markers(additional)
  end

  defp markers(_type), do: []

  # --- build ----------------------------------------------------------------

  defp build_param(%Param{} = param, ctx) do
    {type, ctx} = build_type(param.type, ctx)
    {%{param | type: type}, ctx}
  end

  defp build_type(%Type{kind: :struct, struct: module}, ctx), do: build_struct(module, ctx)

  defp build_type(%Type{kind: :object} = type, ctx) do
    {fields, ctx} = Enum.map_reduce(type.fields || [], ctx, &build_field/2)
    {additional, ctx} = build_type(type.additional, ctx)
    {%{type | fields: fields, additional: additional}, ctx}
  end

  defp build_type(%Type{kind: :array} = type, ctx) do
    {items, ctx} = build_type(type.items, ctx)
    {%{type | items: items}, ctx}
  end

  defp build_type(%Type{kind: :tuple} = type, ctx) do
    {items, ctx} = build_list(type.items, ctx)
    {%{type | items: items}, ctx}
  end

  defp build_type(%Type{kind: :union} = type, ctx) do
    {variants, ctx} = build_list(type.variants, ctx)
    {%{type | variants: variants}, ctx}
  end

  defp build_type(%Type{} = type, ctx), do: {type, ctx}
  defp build_type(nil, ctx), do: {nil, ctx}

  defp build_list(nil, ctx), do: {nil, ctx}
  defp build_list(items, ctx), do: Enum.map_reduce(items, ctx, &build_type/2)

  defp build_field(%Field{} = field, ctx) do
    {type, ctx} = build_type(field.type, ctx)
    {%{field | type: type}, ctx}
  end

  defp build_struct(module, ctx) do
    case Map.get(ctx.cache, module) do
      %{fields: fields, required: required} -> build_cached_struct(module, fields, required, ctx)
      :opaque -> {%Type{kind: :any, source: {:opaque_struct, module}}, ctx}
      _error_or_absent -> {%Type{kind: :any, source: {:unresolved_struct, module}}, ctx}
    end
  end

  defp build_cached_struct(module, fields, required, ctx) do
    if MapSet.member?(ctx.cyclic, module) do
      build_cyclic_struct(module, fields, required, ctx)
    else
      {built, ctx} = build_fields(fields, required, ctx)
      {%Type{kind: :object, struct: module, fields: built, additional: nil}, ctx}
    end
  end

  defp build_cyclic_struct(module, fields, required, ctx) do
    {name, ctx} = struct_def_name(module, ctx)

    case Map.fetch(ctx.struct_defs, name) do
      {:ok, _type} ->
        {%Type{kind: :ref, ref: name}, ctx}

      :error ->
        ctx = %{ctx | struct_defs: Map.put(ctx.struct_defs, name, :building)}
        {built, ctx} = build_fields(fields, required, ctx)
        object = %Type{kind: :object, struct: module, fields: built, additional: nil}

        {%Type{kind: :ref, ref: name},
         %{ctx | struct_defs: Map.put(ctx.struct_defs, name, object)}}
    end
  end

  defp build_fields(fields, required, ctx) do
    fields
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_reduce(ctx, fn {name, type}, ctx ->
      {type, ctx} = build_type(type, ctx)

      field = %Field{
        name: Atom.to_string(name),
        key: name,
        type: type,
        required: MapSet.member?(required, name)
      }

      {field, ctx}
    end)
  end

  defp struct_def_name(module, ctx) do
    case Map.fetch(ctx.struct_names, module) do
      {:ok, name} ->
        {name, ctx}

      :error ->
        name = unique_struct_name(Structs.name(module), module, ctx, 1)
        {name, %{ctx | struct_names: Map.put(ctx.struct_names, module, name)}}
    end
  end

  defp unique_struct_name(base, module, ctx, counter) do
    candidate = if counter == 1, do: base, else: "#{base}_#{counter}"

    taken? =
      MapSet.member?(ctx.existing, candidate) or
        Enum.any?(ctx.struct_names, fn {other, name} -> other != module and name == candidate end)

    if taken?, do: unique_struct_name(base, module, ctx, counter + 1), else: candidate
  end
end
