defmodule ToolCall.Builder do
  @moduledoc false
  # Compile-time assembly: pairs each `def` with its `@doc`, `@spec` and
  # default arguments, then builds the embedded `ToolCall.IR.Tool` list.
  #
  # This runs inside `@before_compile`, never at runtime: `mix release` strips
  # the `Docs` and `Dbgi` chunks, so `Code.Typespec` / `Code.fetch_docs` are not
  # available in production. See docs/pitfalls.md.

  alias ToolCall.{Doc, LocalTypes, Typespec}
  alias ToolCall.IR.{Param, Tool, Type}

  @wire_formats [:number, :string_integer]
  @override_keys [:fun, :name, :wire, :description]
  @literal_sigils [:sigil_s, :sigil_S, :sigil_c, :sigil_C, :sigil_w, :sigil_W]

  @spec build(module(), list(), list(), list(), Macro.Env.t()) :: [Tool.t()]
  def build(module, defs, specs, overrides, env) do
    overrides = normalize_overrides(module, overrides)

    context = %{
      module: module,
      specs: specs,
      overrides: overrides,
      env: env,
      definitions: LocalTypes.definitions(module)
    }

    entries =
      defs
      |> Enum.reverse()
      |> Enum.uniq_by(fn {name, args, _doc, _file, _line} -> {name, length(args)} end)
      |> Enum.flat_map(&build_one(&1, context))
      |> unique_tool_names(module)

    tools = Enum.map(entries, &elem(&1, 0))

    validate_overrides(module, overrides, tools)
    validate_names(module, entries)
    tools
  end

  defp unique_tool_names(entries, module) do
    {entries, _seen} =
      Enum.flat_map_reduce(entries, MapSet.new(), fn {tool, location} = entry, seen ->
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
    for {%Tool{name: name}, location} <- entries, not ToolCall.ProviderName.valid?(name) do
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

    case find_spec(context.specs, name, arity) do
      {nil, _count} ->
        warn_no_spec(context.module, location, name, arity, context.specs)
        []

      {spec, count} ->
        warn_overloads(context.module, location, name, arity, count)
        [{make_tool(name, head_args, doc, spec, context, location), location}]
    end
  end

  defp warn_no_spec(module, location, name, arity, specs) do
    reduced =
      for {:spec, ast, _location} <- specs,
          {^name, spec_arity} <- [spec_signature(ast)],
          spec_arity < arity,
          uniq: true,
          do: spec_arity

    case reduced do
      [] ->
        warn(
          module,
          location,
          "#{name}/#{arity} has no @spec; skipped. A tool without a typespec cannot be described."
        )

      arities ->
        existing = Enum.map_join(Enum.sort(arities), ", ", &"#{name}/#{&1}")

        warn(
          module,
          location,
          "#{name}/#{arity} has no @spec; found #{existing} instead. A reduced arity " <>
            "does not describe the defaulted arguments; add a spec for the full arity."
        )
    end
  end

  defp warn_overloads(_module, _location, _name, _arity, count) when count < 2, do: :ok

  defp warn_overloads(module, location, name, arity, count) do
    warn(
      module,
      location,
      "#{name}/#{arity} has #{count} @spec clauses; using the first one. " <>
        "Overloaded tools cannot be expressed as a single JSON Schema."
    )
  end

  defp visible?(nil), do: true
  defp visible?({_line, false}), do: false
  defp visible?({_line, _text}), do: true

  # `@spec` accumulates newest-first; reverse so "the first one" in the warning
  # means the first declared.
  defp find_spec(specs, name, arity) do
    matching =
      for {:spec, ast, _location} <- specs, match_spec?(ast, name, arity), do: ast

    matching = Enum.reverse(matching)
    {List.first(matching), length(matching)}
  end

  defp match_spec?(spec, name, arity), do: spec_signature(spec) == {name, arity}

  @doc false
  @spec spec_signature(term()) :: {atom(), non_neg_integer()} | nil
  def spec_signature(spec) do
    case unwrap_spec(spec) do
      {{:"::", _, [{fun, _, args}, _return]}, _constraints} when is_atom(fun) and is_list(args) ->
        {fun, length(args)}

      _ ->
        nil
    end
  end

  defp make_tool(name, head_args, doc, spec, context, location) do
    {spec, constraints} = unwrap_spec(spec)
    {:"::", _, [head, _return_ast]} = spec
    {^name, _, spec_args} = head

    bindings = constraint_bindings(constraints)
    defaults = Enum.map(head_args, &default_of/1)
    doc_info = Doc.parse(doc_value(doc))
    arity = length(spec_args)

    params =
      spec_args
      |> Enum.with_index(1)
      |> Enum.map(fn {arg_ast, index} ->
        {param_name, type_ast, named?} = split_arg(arg_ast, index, head_args)
        type_ast = substitute_vars(type_ast, bindings)
        {type_ast, truncated?} = LocalTypes.expand(type_ast, context.definitions)
        type_ast = expand_aliases(type_ast, context.env)

        unless named? do
          warn(
            context.module,
            location,
            "parameter #{index} of #{name}/#{arity} has no name in the @spec; using " <>
              "\"#{param_name}\". Write it as `#{param_name} :: <type>` so the model sees a " <>
              "meaningful property name."
          )
        end

        default = Enum.at(defaults, index - 1)
        type = Typespec.to_type(type_ast)

        if truncated? do
          warn(
            context.module,
            location,
            "parameter \"#{param_name}\" of #{name}/#{arity} hit the type expansion " <>
              "budget; the rest of the type is treated as {}. Flatten the type hierarchy."
          )
        else
          warn_type(context.module, location, type, param_name, name, arity)
        end

        %Param{
          name: param_name,
          type: type,
          description: Map.get(doc_info.params, param_name),
          default: default_value(default, context.env),
          required: default == :none,
          source: type_ast
        }
        |> apply_override(name, context.overrides)
        |> validate_wire_type(context.module, location)
      end)
      |> unique_names(context.module, location, name, arity)

    %Tool{
      name: Atom.to_string(name),
      description: doc_info.description,
      params: params,
      module: context.module,
      fun: name,
      source: spec
    }
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

      Typespec.wire_only?(type) ->
        warn(
          module,
          location,
          "parameter \"#{param_name}\" of #{name}/#{arity} is Decimal.t(); it " <>
            "travels as a decimal string and is not converted. Declare String.t() for the raw " <>
            "string, or convert with Decimal.new/1 in the function."
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

  defp apply_override(%Param{} = param, fun, overrides) do
    case Enum.find(overrides, &(override_fun(&1) == fun and override_name(&1) == param.name)) do
      nil ->
        param

      override ->
        %{
          param
          | wire: Map.get(override, :wire, param.wire),
            description: Map.get(override, :description, param.description)
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

  defp split_arg({:"::", _, [{var, _, ctx}, type]}, index, head_args)
       when is_atom(var) and is_atom(ctx) do
    case Atom.to_string(var) do
      "_" <> _ -> unnamed_arg(type, index, head_args)
      name -> {name, type, true}
    end
  end

  defp split_arg(type_ast, index, head_args), do: unnamed_arg(type_ast, index, head_args)

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
  defp default_value(:none, _env), do: nil

  defp default_value({:ok, ast}, env) do
    case literal(ast, env) do
      {:ok, value} -> value
      :error -> nil
    end
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
           {:ok, value} <- literal(value, env) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        :error -> {:halt, :error}
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

  defp unwrap_spec({:when, _, [spec, constraints]}) when is_list(constraints),
    do: {spec, constraints}

  defp unwrap_spec(spec), do: {spec, []}

  # `@spec id(x) :: x when x: integer()` constrains a type variable, but a tool
  # schema has no variables: bind them to the type the spec gives.
  @doc false
  @spec constraint_bindings(list()) :: map()
  def constraint_bindings(constraints) do
    bindings =
      Enum.reduce(constraints, %{}, fn
        {name, type_ast}, acc when is_atom(name) ->
          Map.put(acc, name, substitute_vars(type_ast, acc))

        _other, acc ->
          acc
      end)

    # A constraint may refer to a variable declared after it (`when x: [t],
    # t: integer()`); the reverse pass resolves that direction without looping
    # on recursive constraints such as `when x: [x]`.
    constraints
    |> Enum.reverse()
    |> Enum.reduce(bindings, fn
      {name, type_ast}, acc when is_atom(name) ->
        Map.put(acc, name, substitute_vars(type_ast, acc))

      _other, acc ->
        acc
    end)
  end

  defp substitute_vars({name, _meta, context} = node, bindings)
       when is_atom(name) and is_atom(context) do
    Map.get(bindings, name, node)
  end

  defp substitute_vars({left, right}, bindings),
    do: {substitute_vars(left, bindings), substitute_vars(right, bindings)}

  defp substitute_vars(list, bindings) when is_list(list),
    do: Enum.map(list, &substitute_vars(&1, bindings))

  defp substitute_vars({head, meta, args}, bindings),
    do: {substitute_vars(head, bindings), meta, substitute_vars(args, bindings)}

  defp substitute_vars(other, _bindings), do: other

  defp doc_value(nil), do: nil
  defp doc_value({_line, value}), do: value

  defp expand_aliases(ast, env), do: Macro.prewalk(ast, &expand_alias(&1, env))

  defp expand_alias({:__aliases__, _, _} = node, env), do: Macro.expand(node, env)
  defp expand_alias({:__MODULE__, _, _} = node, env), do: Macro.expand(node, env)
  defp expand_alias(node, _env), do: node

  defp warn(module, location, message) do
    IO.warn("#{inspect(module)}: #{message}", warn_location(location))
  end

  @doc false
  @spec warn_location({String.t() | nil, pos_integer() | nil}) :: keyword()
  def warn_location({nil, nil}), do: []
  def warn_location({file, nil}), do: [file: file]
  def warn_location({file, line}), do: [file: file, line: line]
end
