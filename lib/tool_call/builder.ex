# reach:disable-for-this-file string_building
# Compile-time diagnostic and $defs names are short lived; iolists would
# obscure the messages without a runtime benefit.
defmodule ToolCall.Builder do
  @moduledoc false
  # Compile-time assembly: pairs each `def` with its declaration and default
  # arguments, then builds the embedded `ToolCall.IR.Tool` list.
  #
  # This runs inside `@before_compile`, never at runtime: `mix release` strips
  # the `Docs` and `Dbgi` chunks, so `Code.Typespec` / `Code.fetch_docs` are not
  # available in production. Typedoc enrichment happens after this module
  # closes; see `ToolCall.__after_compile__/2`. See docs/design.md and the
  # docs/design.md release notes.

  alias ToolCall.{Doc, LocalTypes, Structs, TypeAst, TypeCompiler, Typedoc, Typespec}
  alias ToolCall.IR.{Param, Tool, Type}
  alias ToolCall.TypeSource.Declaration
  alias ToolCall.TypeSource.Param, as: SourceParam

  @wire_formats [:number, :string_integer]
  @override_keys [:fun, :name, :wire, :description]
  @literal_sigils [:sigil_s, :sigil_S, :sigil_c, :sigil_C, :sigil_w, :sigil_W]

  @spec build(module(), list(), list(), Macro.Env.t(), [module()], module()) ::
          %{
            tools: [Tool.t()],
            typedoc_keys: Typedoc.typedoc_keys(),
            indirect: MapSet.t(String.t())
          }
  def build(
        module,
        defs,
        overrides,
        env,
        providers,
        type_source \\ ToolCall.TypeSource.Typespec
      ) do
    overrides = normalize_overrides(module, overrides)
    type_source_state = type_source.load(module, env)

    context = %{
      module: module,
      type_source: type_source,
      type_source_state: type_source_state,
      overrides: overrides,
      env: env,
      providers: providers,
      definitions: definitions(module, env),
      cyclic: cyclic_keys(module, env)
    }

    entries =
      defs
      |> Enum.reverse()
      |> Enum.uniq_by(fn {name, args, _doc, _file, _line} -> {name, length(args)} end)
      |> Enum.flat_map(&build_one(&1, context))
      |> resolve_and_warn(context, module)
      |> unique_tool_names(module)

    tools = Enum.map(entries, &elem(&1, 0))

    indirect =
      for {tool, _location, _truncated, _result_truncated, true} <- entries, do: tool.name

    validate_overrides(module, overrides, tools)
    validate_names(module, entries)

    %{
      tools: tools,
      typedoc_keys: typedoc_keys(tools, context.definitions),
      indirect: MapSet.new(indirect)
    }
  end

  @doc false
  @spec validate_declaration!(Declaration.t(), atom(), non_neg_integer(), list()) :: :ok
  def validate_declaration!(%Declaration{} = declaration, name, arity, head_args) do
    case validate_declaration_checks(declaration, name, arity, head_args) do
      :ok ->
        :ok

      {:error, message} ->
        raise ArgumentError,
              "invalid type source declaration for #{name}/#{arity}: #{message}"
    end
  end

  defp validate_declaration_checks(declaration, name, arity, head_args) do
    with :ok <- validate_declaration_name(declaration, name),
         :ok <- validate_declaration_arity(declaration, arity),
         :ok <- validate_declaration_params(declaration, arity, head_args) do
      validate_declaration_metadata(declaration)
    end
  end

  defp validate_declaration_name(%Declaration{name: name}, name), do: :ok

  defp validate_declaration_name(%Declaration{name: actual}, name) do
    {:error, "declaration name #{inspect(actual)} does not match #{inspect(name)}"}
  end

  defp validate_declaration_arity(%Declaration{arity: arity}, arity), do: :ok

  defp validate_declaration_arity(%Declaration{arity: actual}, arity) do
    {:error, "declaration arity #{actual} does not match #{arity}"}
  end

  defp validate_declaration_params(%Declaration{params: params}, arity, head_args) do
    head_arity = length(head_args)
    param_count = if is_list(params), do: length(params), else: 0

    cond do
      head_arity != arity ->
        {:error, "function head has #{head_arity} arguments, expected #{arity}"}

      not is_list(params) or param_count != arity ->
        {:error, "declaration has #{param_count} params, expected #{arity}"}

      not Enum.all?(params, &match?(%SourceParam{}, &1)) ->
        {:error, "declaration params must be ToolCall.TypeSource.Param structs"}

      true ->
        :ok
    end
  end

  defp valid_diagnostic?(%ToolCall.Diagnostic{severity: severity, message: message})
       when severity in [:warning, :error] and is_binary(message),
       do: true

  defp valid_diagnostic?(_other), do: false

  defp validate_declaration_metadata(%Declaration{} = declaration) do
    cond do
      not is_map(declaration.bindings) ->
        {:error, "declaration bindings must be a map"}

      not is_boolean(declaration.indirect?) ->
        {:error, "declaration indirect? must be a boolean"}

      not is_binary(declaration.source_label) ->
        {:error, "declaration source_label must be a string"}

      not is_list(declaration.warnings) or
          not Enum.all?(declaration.warnings, &valid_diagnostic?/1) ->
        {:error, "declaration warnings must be ToolCall.Diagnostic structs"}

      true ->
        :ok
    end
  end

  defp cyclic_keys(module, env) do
    module
    |> definitions(env)
    |> LocalTypes.cyclic_keys()
  end

  defp definitions(module, env) do
    module
    |> LocalTypes.definitions()
    |> Map.new(fn {key, {params, body}} ->
      {key, {params, TypeAst.normalize(body, env)}}
    end)
  end

  defp typedoc_keys(tools, definitions) do
    # `Typedoc.apply/3` only fills nil descriptions, so a parameter that is
    # already documented by `@doc`, `@tool_param` or an explicit "" needs no
    # key and must not drag its module onto the guarded accessor path.
    for %Tool{name: tool_name, params: params} <- tools,
        %Param{name: param_name, description: nil, source: source} <- params,
        type_keys = Typedoc.keys(source, definitions),
        type_keys != [],
        into: %{} do
      {{tool_name, param_name}, type_keys}
    end
  end

  defp unique_tool_names(entries, module) do
    {entries, _seen} =
      Enum.flat_map_reduce(entries, MapSet.new(), fn {tool, location, _truncated,
                                                      _result_truncated, _indirect?} = entry,
                                                     seen ->
        if MapSet.member?(seen, tool.name) do
          warn(
            module,
            location,
            "tool #{inspect(tool.name)} is defined more than once (same name, different arity); " <>
              "only the first one is exposed. Rename one function or hide it with @doc false."
          )

          {[], seen}
        else
          {[entry], MapSet.put(seen, tool.name)}
        end
      end)

    entries
  end

  defp validate_names(module, entries) do
    for {%Tool{name: name}, location, _truncated, _result_truncated, _indirect?} <- entries,
        not ToolCall.ProviderName.valid?(name) do
      warn(
        module,
        location,
        "tool name #{inspect(name)} is not accepted by OpenAI or Anthropic, which require " <>
          "^[a-zA-Z0-9_-]{1,64}$; rename the function."
      )
    end
  end

  defp build_one({_name, _head_args, doc, _file, _line} = definition, context) do
    if visible?(doc) do
      tools_for(definition, context)
    else
      []
    end
  end

  defp tools_for({name, head_args, doc, file, line}, context) do
    arity = length(head_args)
    location = {file, line}

    case context.type_source.fetch(context.type_source_state, name, arity) do
      {:ok, declaration} ->
        validate_declaration!(declaration, name, arity, head_args)

        for warning <- declaration.warnings,
            do: warn(context.module, location, ToolCall.Diagnostic.message(warning))

        {tool, truncated, result_truncated?} =
          make_tool(name, head_args, doc, declaration, context, location)

        [{tool, location, truncated, result_truncated?, declaration.indirect?}]

      {:error, messages} ->
        for message <- messages,
            do: warn(context.module, location, ToolCall.Diagnostic.message(message))

        []
    end
  end

  defp visible?(nil), do: true
  defp visible?({_line, false}), do: false
  defp visible?({_line, _text}), do: true

  defp make_tool(name, head_args, doc, declaration, context, location) do
    bindings = declaration.bindings
    defaults = Enum.map(head_args, &default_of/1)
    doc_info = Doc.parse(doc_value(doc))
    arity = declaration.arity
    compiler = TypeCompiler.new(context)

    {params, {compiler, truncated}} =
      declaration.params
      |> Enum.zip(defaults)
      |> Enum.with_index(1)
      |> Enum.map_reduce({compiler, MapSet.new()}, fn {{param, default}, index},
                                                      {compiler, truncated} ->
        {param_name, named?} =
          if param.named? do
            {Atom.to_string(param.name), true}
          else
            {fallback, _type_ast, false} = unnamed_arg(param.type, index, head_args)
            {fallback, false}
          end

        {param_name, named?} = doc_param_name(doc_info, index, param_name, named?)

        {type, source_ast, param_truncated?, compiler} =
          TypeCompiler.compile_param(compiler, param.type, bindings)

        if not named? do
          warn(
            context.module,
            location,
            "parameter #{index} of #{name}/#{arity} has no name in " <>
              "#{declaration.source_label}; using \"#{param_name}\". Write it as " <>
              "`#{param_name} :: <type>` so the model sees a meaningful property name."
          )
        end

        if param_truncated? do
          warn(
            context.module,
            location,
            "parameter \"#{param_name}\" of #{name}/#{arity} hit the type expansion " <>
              "budget; the rest of the type is treated as {}. Flatten the type hierarchy."
          )
        end

        truncated =
          if param_truncated?, do: MapSet.put(truncated, param_name), else: truncated

        {%Param{
           name: param_name,
           type: type,
           default: default_value(default, context.env, type),
           required: default == :none,
           source: source_ast
         }, {compiler, truncated}}
      end)

    params =
      params
      |> Enum.map(&apply_doc_description(&1, doc_info))
      |> unique_names(context.module, location, name, arity)
      |> Enum.map(fn param ->
        param
        |> apply_doc_description(doc_info)
        |> apply_override(name, context.overrides)
        |> validate_wire_type(context.module, location)
        |> drop_incompatible_default(context.module, location, name, arity)
      end)

    warn_unknown_doc_bullets(context.module, location, name, arity, doc_info, params)

    {result, result_truncated?, compiler} =
      TypeCompiler.compile_result(compiler, declaration.return, bindings)

    if result_truncated? do
      warn(
        context.module,
        location,
        "return type of #{name}/#{arity} hit the type expansion budget; the rest of " <>
          "the type is treated as {}. Result validation will accept any value there."
      )
    end

    {%Tool{
       name: Atom.to_string(name),
       description: doc_info.description,
       params: params,
       module: context.module,
       fun: name,
       source: declaration.source,
       defs: TypeCompiler.defs(compiler),
       result: result
     }, truncated, result_truncated?}
  end

  defp warn_unknown_doc_bullets(
         _module,
         _location,
         _name,
         _arity,
         %{param_heading: :options},
         _params
       ),
       do: :ok

  defp warn_unknown_doc_bullets(module, location, name, arity, doc_info, params) do
    names = MapSet.new(params, & &1.name)

    for {doc_name, _description} <- doc_info.params,
        not MapSet.member?(names, doc_name) do
      warn(
        module,
        location,
        "@doc for #{name}/#{arity} documents #{inspect(doc_name)}, which is not a parameter; " <>
          "the bullet is ignored."
      )
    end
  end

  defp drop_incompatible_default(%Param{default: nil} = param, _module, _location, _name, _arity),
    do: param

  defp drop_incompatible_default(
         %Param{name: param_name, type: type, default: default} = param,
         module,
         location,
         name,
         arity
       ) do
    cond do
      Typespec.default_compatible?(type, default) ->
        param

      intentional_atom_default?(type, default) ->
        %{param | default: nil}

      true ->
        warn(
          module,
          location,
          "default for parameter \"#{param_name}\" of #{name}/#{arity} is not compatible " <>
            "with its type; dropping it."
        )

        %{param | default: nil}
    end
  end

  defp intentional_atom_default?(%Type{kind: :atom}, value),
    do: is_boolean(value) or is_nil(value)

  defp intentional_atom_default?(%Type{kind: :array, items: items}, values)
       when is_list(values) do
    item_type = items || %Type{kind: :any}
    Enum.any?(values, &intentional_atom_default?(item_type, &1))
  end

  defp intentional_atom_default?(%Type{kind: :tuple, items: items}, values)
       when is_list(items) and is_list(values) do
    if length(items) == length(values) do
      items
      |> Enum.zip(values)
      |> Enum.any?(fn {type, value} -> intentional_atom_default?(type, value) end)
    else
      Enum.any?(items, &contains_atom_type?/1) and
        Enum.any?(values, &(is_boolean(&1) or is_nil(&1)))
    end
  end

  defp intentional_atom_default?(%Type{kind: :object} = type, value) when is_map(value) do
    fields = type.fields || []
    additional = type.additional || %Type{kind: :any}

    Enum.any?(value, fn {key, item} ->
      intentional_atom_default?(field_default_type(fields, additional, key), item)
    end)
  end

  defp intentional_atom_default?(_type, _value), do: false

  defp contains_atom_type?(%Type{kind: :atom}), do: true

  defp contains_atom_type?(%Type{kind: :union, variants: variants}),
    do: Enum.any?(variants || [], &contains_atom_type?/1)

  defp contains_atom_type?(_type), do: false

  defp field_default_type(fields, additional, key) do
    Enum.find_value(fields, additional, fn field ->
      if field.key == key or field.name == key, do: field.type
    end)
  end

  defp unique_names(params, module, location, fun, arity) do
    {params, _seen} =
      Enum.map_reduce(params, MapSet.new(), fn param, seen ->
        if MapSet.member?(seen, param.name) do
          unique = unique_name(param.name, seen, 2)

          warn(
            module,
            location,
            "parameter name #{inspect(param.name)} of #{fun}/#{arity} is used twice; " <>
              "the duplicate is exposed as #{inspect(unique)}. Rename one of them in the @spec."
          )

          {%{param | name: unique}, MapSet.put(seen, unique)}
        else
          {param, MapSet.put(seen, param.name)}
        end
      end)

    params
  end

  defp unique_name(name, seen, counter) do
    candidate = "#{name}_#{counter}"
    if MapSet.member?(seen, candidate), do: unique_name(name, seen, counter + 1), else: candidate
  end

  defp validate_wire_type(
         %Param{wire: :string_integer, type: %Type{kind: kind}} = param,
         module,
         location
       )
       when kind != :integer do
    warn(
      module,
      location,
      "wire: :string_integer applies only to integer() parameters; ignoring it for " <>
        "\"#{param.name}\"."
    )

    %{param | wire: :number}
  end

  defp validate_wire_type(%Param{} = param, _module, _location), do: param

  defp resolve_and_warn(entries, context, module) do
    {entries, _raw} =
      Enum.map_reduce(entries, %{}, fn {tool, location, truncated, result_truncated, indirect?},
                                       raw ->
        {tool, warnings, raw} =
          Structs.Resolve.run(
            tool,
            context.providers,
            raw,
            &TypeAst.normalize(&1, context.env)
          )

        Enum.each(warnings, &warn(module, location, &1))
        expose(module, location, tool, truncated, result_truncated, indirect?, raw)
      end)

    Enum.reject(entries, &is_nil/1)
  end

  # A parameter with no JSON type cannot be described to a model, and a tool
  # with one is not a contract the model can honour. Skipping it keeps the
  # compile total and mirrors `@doc false`; the warning names the fix.
  defp expose(module, location, %Tool{} = tool, truncated, result_truncated, indirect?, raw) do
    defs = tool.defs

    case Enum.find(tool.params, fn param ->
           root_unrepresentable?(param.type) or required_unrepresentable?(param.type, defs)
         end) do
      nil ->
        warn_tool(module, location, tool, truncated, result_truncated)
        {{tool, location, truncated, result_truncated, indirect?}, raw}

      %Param{name: param} ->
        warn(
          module,
          location,
          "tool #{inspect(tool.name)} is not exposed: parameter \"#{param}\" has no JSON " <>
            "type (term/any, an unrepresentable type, or a remote type with no provider). " <>
            "Narrow the type, add a TypeProvider, or hide the function with @doc false."
        )

        {nil, raw}
    end
  end

  defp root_unrepresentable?(%Type{kind: kind}), do: kind in [:any, :unsupported]
  defp root_unrepresentable?(_type), do: false

  defp required_unrepresentable?(type, defs) do
    required_unrepresentable?(type, defs, [])
  end

  defp required_unrepresentable?(%Type{nullable: true}, _defs, _seen), do: false

  defp required_unrepresentable?(%Type{kind: :unsupported}, _defs, _seen), do: true

  defp required_unrepresentable?(%Type{kind: :object} = type, defs, seen) do
    Enum.any?(type.fields || [], fn field ->
      field.required and required_unrepresentable?(field.type, defs, seen)
    end)
  end

  defp required_unrepresentable?(%Type{kind: :array} = type, defs, seen) do
    (type.minimum || 0) > 0 and required_unrepresentable?(type.items, defs, seen)
  end

  defp required_unrepresentable?(%Type{kind: :tuple, items: items}, defs, seen)
       when is_list(items) do
    Enum.any?(items, &required_unrepresentable?(&1, defs, seen))
  end

  defp required_unrepresentable?(%Type{kind: :union, variants: variants}, defs, seen)
       when is_list(variants) do
    variants != [] and Enum.all?(variants, &required_unrepresentable?(&1, defs, seen))
  end

  defp required_unrepresentable?(%Type{kind: :ref, ref: ref}, defs, seen) when is_map(defs) do
    if ref in seen do
      false
    else
      case Map.fetch(defs, ref) do
        {:ok, type} -> required_unrepresentable?(type, defs, [ref | seen])
        :error -> false
      end
    end
  end

  defp required_unrepresentable?(_type, _defs, _seen), do: false

  defp warn_tool(module, location, %Tool{} = tool, truncated, result_truncated) do
    arity = length(tool.params)

    Enum.each(tool.params, fn param ->
      if not MapSet.member?(truncated, param.name) do
        warn_type(module, location, param.type, param.name, tool.fun, arity)
      end
    end)

    reachable = ToolCall.Defs.reachable(Enum.map(tool.params, & &1.type), tool.defs)

    Enum.each(tool.defs, fn {name, type} ->
      if MapSet.member?(reachable, name) do
        warn_def(module, location, name, type, tool.fun, arity)
      end
    end)

    warn_result_type(module, location, tool, arity, result_truncated)
  end

  @max_result_paths 5

  defp warn_result_type(_module, _location, %Tool{}, _arity, true), do: :ok

  defp warn_result_type(module, location, %Tool{} = tool, arity, false) do
    case Map.get(tool, :result) do
      nil -> :ok
      %Type{} = result -> warn_result_paths(module, location, tool, arity, result)
    end
  end

  defp warn_result_paths(module, location, tool, arity, result) do
    fun = Map.get(tool, :fun)

    paths =
      result
      |> result_paths(Map.get(tool, :defs) || %{}, [], "")
      |> Enum.uniq()

    case Enum.find(paths, fn {path, _reason} -> is_nil(path) end) do
      {nil, reason} ->
        warn_root_result(
          module,
          location,
          fun,
          arity,
          reason,
          Map.get(result, :kind),
          Map.get(result, :source)
        )

      nil ->
        warn_nested_result(module, location, fun, arity, paths)
    end
  end

  defp warn_root_result(
         module,
         location,
         fun,
         arity,
         {:opaque, struct},
         :any,
         {:opaque_struct, struct}
       ) do
    warn(
      module,
      location,
      "return type of #{fun}/#{arity} is #{inspect(struct)}.t(), which is " <>
        "@opaque; run/4 with validate_result: true will accept any value."
    )
  end

  defp warn_root_result(
         module,
         location,
         fun,
         arity,
         {:unresolved, struct},
         :any,
         {:unresolved_struct, struct}
       ) do
    warn(
      module,
      location,
      "return type of #{fun}/#{arity} could not resolve #{inspect(struct)}; " <>
        "run/4 with validate_result: true will accept any value."
    )
  end

  defp warn_root_result(module, location, fun, arity, _reason, _kind, _source) do
    warn(
      module,
      location,
      "return type of #{fun}/#{arity} cannot be validated; run/4 with " <>
        "validate_result: true will accept any value. Narrow the type or add a " <>
        "validator if the result must be checked."
    )
  end

  defp warn_nested_result(_module, _location, _fun, _arity, []), do: :ok

  defp warn_nested_result(module, location, fun, arity, paths) do
    listed =
      paths
      |> Enum.map(fn {path, _reason} -> inspect(format_result_path(path)) end)
      |> Enum.take(@max_result_paths)

    more = length(paths) - length(listed)
    suffix = if more > 0, do: " (and #{more} more)", else: ""

    warn(
      module,
      location,
      "return type of #{fun}/#{arity} cannot be validated at " <>
        Enum.join(listed, ", ") <>
        suffix <>
        "; run/4 with validate_result: true will accept any value there. " <>
        "Narrow the type or add a validator if the result must be checked."
    )
  end

  defp result_paths(type, defs, seen, path) when is_map(type) do
    if Map.get(type, :validator) do
      []
    else
      result_paths_kind(type, defs, seen, path)
    end
  end

  defp result_paths(nil, _defs, _seen, _path), do: []

  defp result_paths_kind(type, defs, seen, path) when is_map(type) do
    case Map.get(type, :kind) do
      :any -> result_paths_any(type, path)
      :unsupported -> [{root_result_path(path), :unsupported}]
      :ref -> result_paths_ref(type, defs, seen, path)
      :object -> result_paths_object(type, defs, seen, path)
      :array -> result_paths(Map.get(type, :items), defs, seen, path <> "[]")
      :tuple -> result_paths_tuple(type, defs, seen, path)
      :union -> result_paths_union(type, defs, seen, path)
      _other -> []
    end
  end

  defp result_paths_any(type, path) do
    [{root_result_path(path), result_reason(Map.get(type, :source))}]
  end

  defp result_paths_ref(type, defs, seen, path) do
    ref = Map.get(type, :ref)

    if ref in seen do
      []
    else
      case Map.fetch(defs, ref) do
        {:ok, nested} -> result_paths(nested, defs, [ref | seen], path)
        :error -> [{root_result_path(path), {:missing_ref, ref}}]
      end
    end
  end

  defp result_paths_object(type, defs, seen, path) do
    fields =
      type
      |> Map.get(:fields)
      |> List.wrap()
      |> Enum.flat_map(fn field ->
        result_paths(
          Map.get(field, :type),
          defs,
          seen,
          result_field_path(path, Map.get(field, :name))
        )
      end)

    additional =
      case Map.get(type, :additional) do
        nil -> []
        additional -> result_paths(additional, defs, seen, result_field_path(path, "*"))
      end

    fields ++ additional
  end

  defp result_paths_tuple(type, defs, seen, path) do
    type
    |> Map.get(:items)
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} ->
      result_paths(item, defs, seen, path <> "[" <> Integer.to_string(index) <> "]")
    end)
  end

  defp result_paths_union(type, defs, seen, path) do
    type
    |> Map.get(:variants)
    |> List.wrap()
    |> Enum.flat_map(&result_paths(&1, defs, seen, path))
  end

  defp root_result_path(""), do: nil
  defp root_result_path(path), do: path

  defp result_field_path("", name), do: name
  defp result_field_path(path, name), do: path <> "." <> name

  defp result_reason({:opaque_struct, struct}), do: {:opaque, struct}
  defp result_reason({:unresolved_struct, struct}), do: {:unresolved, struct}
  defp result_reason(_source), do: :no_validator

  defp format_result_path(path) when byte_size(path) > 40, do: String.slice(path, 0, 37) <> "..."
  defp format_result_path(path), do: path

  defp warn_def(module, location, name, type, fun, arity) do
    where = "$defs entry \"#{name}\" of #{fun}/#{arity}"

    cond do
      Typespec.unrepresentable?(type) ->
        warn(
          module,
          location,
          where <> " has no JSON representation; the model will see {} for it."
        )

      Typespec.open_object?(type) ->
        warn(
          module,
          location,
          where <>
            " has an open object; emit(..., strict: true) closes it, so the model " <>
            "can only send {}. Use a fixed-shape map, or do not use strict."
        )

      Typespec.untyped?(type) ->
        warn(
          module,
          location,
          where <>
            " has no JSON type; emit(..., strict: true) cannot express it. " <>
            "Narrow the type to give the model a schema it can follow."
        )

      Typespec.tuple?(type) ->
        warn(
          module,
          location,
          where <>
            " is a tuple; emit(..., strict: true) cannot express positions (the API " <>
            "rejects prefixItems), so the model sees a fixed-size array with unconstrained " <>
            "items. Use a fixed-shape object, or do not use strict."
        )

      true ->
        :ok
    end
  end

  defp warn_type(module, location, type, param_name, name, arity) do
    cond do
      Typespec.unrepresentable?(type) ->
        warn(
          module,
          location,
          "parameter \"#{param_name}\" of #{name}/#{arity} has no JSON " <>
            "representation; the model will see {} for it. Use a JSON-compatible type or " <>
            "@doc false to opt the function out."
        )

      Typespec.open_object?(type) ->
        warn(
          module,
          location,
          "parameter \"#{param_name}\" of #{name}/#{arity} has an open " <>
            "object; emit(..., strict: true) closes it with additionalProperties: false, " <>
            "so the model can only send {}. Use a fixed-shape map, or do not use strict."
        )

      Typespec.untyped?(type) ->
        warn(
          module,
          location,
          "parameter \"#{param_name}\" of #{name}/#{arity} has no JSON " <>
            "type; emit(..., strict: true) cannot express it. Narrow the type to give the " <>
            "model a schema it can follow."
        )

      Typespec.tuple?(type) ->
        warn(
          module,
          location,
          "parameter \"#{param_name}\" of #{name}/#{arity} is a tuple; " <>
            "emit(..., strict: true) cannot express positions (the API rejects prefixItems), " <>
            "so the model sees a fixed-size array with unconstrained items. Use a fixed-shape " <>
            "object, or do not use strict."
        )

      true ->
        :ok
    end
  end

  defp apply_doc_description(%Param{} = param, %{param_heading: :options}), do: param

  defp apply_doc_description(%Param{} = param, doc_info) do
    case Map.fetch(doc_info.params, param.name) do
      {:ok, description} -> %{param | description: description}
      :error -> param
    end
  end

  defp apply_override(%Param{} = param, fun, overrides) do
    case Enum.find(overrides, &(override_fun(&1) == fun and override_name(&1) == param.name)) do
      nil ->
        param

      override ->
        %{
          param
          | wire: Map.get(override, :wire, param.wire),
            description: Map.get(override, :description) || param.description
        }
    end
  end

  defp override_fun(override), do: Map.fetch!(override, :fun)
  defp override_name(override), do: to_string(Map.fetch!(override, :name))

  defp normalize_overrides(module, overrides) do
    Enum.flat_map(overrides, fn
      %{fun: fun, name: name} = override
      when is_atom(fun) and (is_atom(name) or is_binary(name)) ->
        override = validate_override_keys(module, override)
        override = validate_override_description(module, override)
        [validate_wire(module, override)]

      other ->
        warn(
          module,
          {nil, nil},
          "expected @tool_param %{fun: :function, name: ...}, got: #{inspect(other)}"
        )

        []
    end)
  end

  defp validate_override_keys(module, override) do
    case Map.keys(override) -- @override_keys do
      [] ->
        override

      unknown ->
        warn(
          module,
          {nil, nil},
          "unknown key(s) #{inspect(unknown)} in @tool_param for #{inspect(override.fun)}; " <>
            "expected :fun, :name, :wire and :description. Ignoring them."
        )

        Map.drop(override, unknown)
    end
  end

  defp validate_override_description(module, override) do
    case Map.fetch(override, :description) do
      {:ok, description} when is_binary(description) or is_nil(description) ->
        override

      {:ok, other} ->
        warn(
          module,
          {nil, nil},
          "description in @tool_param for #{inspect(override.fun)}/#{inspect(override.name)} " <>
            "must be a string, got: #{inspect(other)}; ignoring it."
        )

        Map.delete(override, :description)

      :error ->
        override
    end
  end

  defp validate_wire(module, override) do
    case Map.fetch(override, :wire) do
      {:ok, wire} when wire in @wire_formats ->
        override

      {:ok, wire} ->
        warn(
          module,
          {nil, nil},
          "unknown wire format #{inspect(wire)} in @tool_param for #{inspect(override.fun)}; " <>
            "expected :number or :string_integer. Falling back to :number."
        )

        Map.delete(override, :wire)

      :error ->
        override
    end
  end

  defp validate_overrides(module, overrides, tools) do
    overrides
    |> Enum.group_by(&{override_fun(&1), override_name(&1)})
    |> Enum.each(fn
      {{fun, name}, [_one, _two | _]} ->
        warn(
          module,
          {nil, nil},
          "duplicate @tool_param for #{inspect(fun)}/#{inspect(name)}; only one is used."
        )

      _single ->
        :ok
    end)

    for override <- overrides do
      fun = override_fun(override)
      name = override_name(override)
      candidates = Enum.filter(tools, &(&1.fun == fun))

      cond do
        candidates == [] ->
          warn(
            module,
            {nil, nil},
            "unknown tool #{inspect(fun)} in @tool_param; it matches no public function with a @spec"
          )

        not Enum.any?(candidates, fn tool -> Enum.any?(tool.params, &(&1.name == name)) end) ->
          warn(
            module,
            {nil, nil},
            "unknown parameter #{inspect(name)} of tool #{inspect(fun)} in @tool_param"
          )

        true ->
          :ok
      end
    end
  end

  defp doc_param_name(%{param_order: names}, index, fallback, false) do
    case Enum.at(names, index - 1) do
      nil -> {fallback, false}
      name -> {name, true}
    end
  end

  defp doc_param_name(_doc_info, _index, fallback, true), do: {fallback, true}

  defp unnamed_arg(type_ast, index, head_args) do
    fallback = head_args |> Enum.at(index - 1) |> head_var_name() || "arg#{index}"
    {fallback, type_ast, false}
  end

  defp head_var_name({:\\, _, [inner, _default]}), do: head_var_name(inner)

  defp head_var_name({var, _, ctx}) when is_atom(var) and is_atom(ctx) do
    case Atom.to_string(var) do
      "_" <> _ -> nil
      name -> name
    end
  end

  defp head_var_name(_other), do: nil

  defp default_of({:\\, _, [_, default]}), do: {:ok, default}
  defp default_of(_other), do: :none

  # Only compile-time literals can be shown to the model. Anything else (a
  # call such as `DateTime.utc_now()`, an interpolation) would reach the
  # schema as a quoted AST, so it is dropped; the parameter stays optional.
  defp default_value(:none, _env, _type), do: nil

  defp default_value({:ok, ast}, env, type) do
    ast = expand_module_attributes(ast, env)

    case typed_literal(ast, type, env) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp expand_module_attributes(ast, %Macro.Env{module: module}) do
    Macro.prewalk(ast, fn
      {:@, _, [{name, _, context}]} = node when is_atom(name) and is_atom(context) ->
        value = Module.get_attribute(module, name)

        if is_struct(value), do: node, else: Macro.escape(value)

      node ->
        node
    end)
  end

  defp literal(value, _env) when is_number(value) or is_binary(value) or is_atom(value),
    do: {:ok, value}

  defp literal({:-, _, [number]}, _env) when is_number(number), do: {:ok, -number}

  defp literal(list, env) when is_list(list) do
    case literals(list, env) do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  defp literal({:%{}, _, pairs}, env) do
    pairs
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with {:ok, key} <- literal(key, env),
           true <- is_atom(key) or is_binary(key),
           {:ok, value} <- literal(value, env) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        _other -> {:halt, :error}
      end
    end)
  end

  # Sigil macros are compile-time expressions; expand the safe literal forms so
  # `~s`, `~c` and `~w` defaults are not lost. Dates, regexes and interpolated
  # sigils stay out: their value is not JSON data.
  defp literal({sigil, _, _} = ast, env) when sigil in @literal_sigils do
    literal(Macro.expand(ast, env), env)
  end

  defp literal(_other, _env), do: :error

  defp literals(elements, env) do
    Enum.reduce_while(elements, {:ok, []}, fn element, {:ok, acc} ->
      case literal(element, env) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp typed_literal(ast, %Type{kind: :object, source: :keyword} = type, env) do
    keyword_literal(ast, type.additional || %Type{kind: :any}, env)
  end

  defp typed_literal(ast, %Type{kind: :array, items: items}, env) when is_list(ast) do
    item_type = items || %Type{kind: :any}

    ast
    |> Enum.reduce_while({:ok, []}, fn element, {:ok, acc} ->
      case typed_literal(element, item_type, env) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  defp typed_literal({:%{}, _, pairs}, %Type{kind: :object} = type, env) do
    type = %{type | fields: type.fields || []}

    Enum.reduce_while(pairs, {:ok, %{}}, fn {key_ast, value_ast}, {:ok, acc} ->
      with {:ok, key} <- literal(key_ast, env),
           true <- is_atom(key) or is_binary(key),
           value_type = typed_field_type(type, key),
           {:ok, value} <- typed_literal(value_ast, value_type, env) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        _other -> {:halt, :error}
      end
    end)
  end

  defp typed_literal(ast, %Type{kind: :union, variants: variants}, env) do
    variants
    |> List.wrap()
    |> Enum.find_value(:error, &union_literal(ast, &1, env))
  end

  defp typed_literal(ast, _type, env), do: literal(ast, env)

  defp union_literal(ast, variant, env) do
    with {:ok, value} <- typed_literal(ast, variant, env),
         true <- Typespec.default_compatible?(variant, value) do
      {:ok, value}
    else
      _other -> nil
    end
  end

  defp typed_field_type(%Type{} = type, key) do
    fields = type.fields || []
    default = type.additional || %Type{kind: :any}

    Enum.find_value(fields, default, fn field ->
      if field.key == key or field.name == key, do: field.type
    end)
  end

  defp keyword_literal(list, value_type, env) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, %{}}, fn
      {key, value}, {:ok, acc} when is_atom(key) ->
        case typed_literal(value, value_type, env) do
          {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
          :error -> {:halt, :error}
        end

      _other, _acc ->
        {:halt, :error}
    end)
  end

  defp keyword_literal(_other, _value_type, _env), do: :error

  defp doc_value(nil), do: nil
  defp doc_value({_line, value}), do: value

  defp warn(module, location, message) do
    IO.warn("#{inspect(module)}: #{message}", warn_location(location))
  end

  @doc false
  @spec warn_location({String.t() | nil, pos_integer() | nil}) :: keyword()
  def warn_location({nil, nil}), do: []
  def warn_location({file, nil}), do: [file: file]
  def warn_location({file, line}), do: [file: file, line: line]
end
