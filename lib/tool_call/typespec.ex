defmodule ToolCall.Typespec do
  @moduledoc """
  Converts a quoted typespec AST (aliases already expanded) into `ToolCall.IR.Type`.

  This module is deliberately total: unknown shapes degrade to `:any` rather
  than raising, so that adding a new typespec construct to a codebase never
  breaks compilation of unrelated tools.
  """

  alias ToolCall.IR.{Field, Param, Tool, Type}
  alias ToolCall.Patterns
  alias ToolCall.Providers.Stdlib
  alias ToolCall.Structs

  @unrepresentable [:fun, :pid, :port, :reference, :mfa, :no_return, :none]

  @builtin_providers [Stdlib]

  @doc false
  @spec builtin_providers() :: [module()]
  def builtin_providers, do: @builtin_providers

  @doc """
  Maps a quoted type to a `ToolCall.IR.Type`.

  Aliases must already be expanded (`Macro.expand/2`), otherwise remote types
  such as `String.t()` arrive as `{:__aliases__, ...}` and degrade to `:any`.

  Built-in providers resolve `String`, `Keyword`, `Path` and the calendar types
  and are used by default. Passing `providers` explicitly replaces that default;
  `use ToolCall, types: [...]` prepends the built-ins before the user list. A
  provider must return a well-formed IR node: an unknown kind, a non-string or
  uncompilable pattern, a malformed transform, enum values, bounds, bound
  ordering, array minimums, formats, nullability, field metadata, or malformed
  `fields`/`items`/`variants`/`additional` raises at compile time.
  """
  @spec to_type(term(), [module()]) :: Type.t()
  def to_type(ast, providers \\ @builtin_providers)

  # --- literals -------------------------------------------------------------

  def to_type(nil, _providers), do: %Type{kind: :null, source: nil}
  def to_type(true, _providers), do: %Type{kind: :enum, values: [true], source: true}
  def to_type(false, _providers), do: %Type{kind: :enum, values: [false], source: false}

  def to_type(atom, _providers) when is_atom(atom) and atom not in [nil, true, false] do
    %Type{kind: :enum, values: [atom], source: atom}
  end

  def to_type(int, _providers) when is_integer(int) do
    %Type{kind: :integer, minimum: int, maximum: int, source: int}
  end

  def to_type(float, _providers) when is_float(float) do
    %Type{kind: :float, source: float}
  end

  def to_type({:-, _, [number]}, providers) when is_number(number),
    do: to_type(-number, providers)

  # --- compound forms -------------------------------------------------------

  def to_type({{:., _, [:tool_call_ref, :ref]}, _, [ref]}, _providers) when is_binary(ref),
    do: %Type{kind: :ref, ref: ref}

  def to_type({:|, _, [left, right]}, providers) do
    [left, right]
    |> Enum.flat_map(&flatten_union(&1, providers))
    |> build_union()
  end

  def to_type({:.., _, [low, high]}, providers) do
    case {int_literal(low), int_literal(high)} do
      {{:ok, low}, {:ok, high}} -> %Type{kind: :integer, minimum: low, maximum: high}
      _ -> local(:.., [low, high], providers)
    end
  end

  def to_type({:%, _, [module, {:%{}, _, _fields}]}, providers) when is_atom(module) do
    remote(module, :t, [], providers)
  end

  def to_type({:%{}, _, pairs}, providers), do: build_object(pairs, providers)

  def to_type({:{}, _, elements}, providers) do
    %Type{kind: :tuple, items: Enum.map(elements, &to_type(&1, providers))}
  end

  def to_type({left, right}, providers) do
    %Type{kind: :tuple, items: [to_type(left, providers), to_type(right, providers)]}
  end

  # `[t]` is a one-element list in the AST; `[]` is an empty list literal.
  def to_type([{:->, _, _}], _providers), do: %Type{kind: :unsupported, source: :fun}
  def to_type([type], providers), do: %Type{kind: :array, items: to_type(type, providers)}
  def to_type([], _providers), do: %Type{kind: :array, items: %Type{kind: :any}}

  # Remote types, e.g. String.t() or Date.t()
  def to_type({{:., _, [module, function]}, _, args}, providers) when is_atom(module) do
    remote(module, function, args, providers)
  end

  # Local type calls, e.g. integer() or keyword(String.t())
  def to_type({name, _, args}, providers) when is_atom(name) and is_list(args) do
    local(name, args, providers)
  end

  def to_type(other, _providers), do: %Type{kind: :any, source: other}

  # --- local types ----------------------------------------------------------

  defp local(:integer, [], _providers), do: %Type{kind: :integer}
  defp local(:non_neg_integer, [], _providers), do: %Type{kind: :integer, minimum: 0}
  defp local(:pos_integer, [], _providers), do: %Type{kind: :integer, minimum: 1}
  defp local(:neg_integer, [], _providers), do: %Type{kind: :integer, maximum: -1}
  defp local(:byte, [], _providers), do: %Type{kind: :integer, minimum: 0, maximum: 255}
  defp local(:float, [], _providers), do: %Type{kind: :float}
  defp local(:number, [], _providers), do: %Type{kind: :number}

  defp local(:atom, [], _providers), do: %Type{kind: :atom}
  defp local(:module, [], _providers), do: %Type{kind: :atom}
  defp local(:boolean, [], _providers), do: %Type{kind: :boolean}

  defp local(:binary, [], _providers), do: %Type{kind: :string, source: :binary}
  defp local(:bitstring, [], _providers), do: %Type{kind: :string, source: :bitstring}
  defp local(:string, [], _providers), do: %Type{kind: :string, source: :string}
  defp local(:charlist, [], _providers), do: %Type{kind: :string, source: :charlist}

  defp local(:char, [], _providers) do
    %Type{
      kind: :string,
      pattern: Patterns.char(),
      pattern_regex: Patterns.regex(Patterns.char()),
      source: :char
    }
  end

  defp local(:list, [], _providers), do: %Type{kind: :array, items: %Type{kind: :any}}
  defp local(:list, [type], providers), do: %Type{kind: :array, items: to_type(type, providers)}

  defp local(:nonempty_list, [], _providers) do
    %Type{kind: :array, items: %Type{kind: :any}, minimum: 1}
  end

  defp local(:nonempty_list, [type], providers) do
    %Type{kind: :array, items: to_type(type, providers), minimum: 1}
  end

  defp local(:nonempty_binary, [], _providers), do: nonempty_string_type(:binary)
  defp local(:nonempty_string, [], _providers), do: nonempty_string_type(:string)

  defp local(:keyword, args, providers) do
    case args do
      [] -> Stdlib.keyword_type(%Type{kind: :any})
      [type] -> ToolCall.Providers.Stdlib.keyword_type(to_type(type, providers))
      other -> %Type{kind: :any, source: {:keyword, other}}
    end
  end

  defp local(:map, [], _providers),
    do: %Type{kind: :object, fields: [], additional: %Type{kind: :any}}

  defp local(:tuple, [], _providers), do: %Type{kind: :tuple, items: nil}

  defp local(:as_boolean, [type], providers), do: to_type(type, providers)
  defp local(:as_boolean, [], _providers), do: %Type{kind: :boolean}

  defp local(name, [], _providers) when name in [:term, :any], do: %Type{kind: :any, source: name}

  defp local(name, [], _providers) when name in @unrepresentable,
    do: %Type{kind: :unsupported, source: name}

  defp local(:fun, _args, _providers), do: %Type{kind: :unsupported, source: :fun}

  defp local(:struct, [], _providers),
    do: %Type{kind: :object, fields: [], additional: %Type{kind: :any}}

  defp local(name, args, _providers) do
    %Type{kind: :any, source: {name, args}}
  end

  defp nonempty_string_type(source) do
    %Type{
      kind: :string,
      source: source,
      pattern: Patterns.nonempty(),
      pattern_regex: Patterns.regex(Patterns.nonempty())
    }
  end

  # --- remote types ---------------------------------------------------------

  defp remote(module, function, args, providers) do
    resolved_args = Enum.map(args, &to_type(&1, providers))

    case Enum.find_value(providers, &resolve_provider(&1, module, function, resolved_args)) do
      nil -> unresolved_remote(module, function, args)
      type -> type
    end
  end

  defp unresolved_remote(module, :t, []) do
    if Structs.struct?(module),
      do: %Type{kind: :struct, struct: module},
      else: %Type{kind: :any, source: {module, :t, []}}
  end

  defp unresolved_remote(module, function, args),
    do: %Type{kind: :any, source: {module, function, args}}

  defp resolve_provider(provider, module, function, args) do
    case provider.resolve(module, function, args) do
      {:ok, %Type{} = type} ->
        type
        |> maybe_provider_coerce(provider)
        |> validate_provider_type!(provider, module, function, args)

      :error ->
        nil

      other ->
        provider_type_error!(
          provider,
          module,
          function,
          args,
          "returned #{inspect(other)}"
        )
    end
  end

  defp maybe_provider_coerce(%Type{} = type, provider) do
    if function_exported?(provider, :coerce, 1),
      do: %{type | transform: {provider, :coerce}},
      else: type
  end

  defp validate_provider_type!(%Type{kind: :struct}, _provider, _module, _function, _args) do
    raise ArgumentError,
          "invalid ToolCall IR: :struct is an internal resolution marker; " <>
            "resolve the tool before validating it"
  end

  defp validate_provider_type!(%Type{} = type, provider, module, function, args) do
    if type.kind not in Type.kinds() do
      provider_type_error!(
        provider,
        module,
        function,
        args,
        "unknown kind #{inspect(type.kind)}"
      )
    end

    type = validate_ref!(type, provider, module, function, args)
    type = validate_pattern!(type, provider, module, function, args)
    validate_transform!(type, provider, module, function, args)
    type = validate_metadata!(type, provider, module, function, args)
    validate_children!(type, provider, module, function, args)
  end

  defp validate_pattern!(%Type{pattern: nil} = type, _provider, _module, _function, _args),
    do: %{type | pattern_regex: nil}

  defp validate_pattern!(
         %Type{pattern: pattern} = type,
         provider,
         module,
         function,
         args
       )
       when is_binary(pattern) do
    if String.valid?(pattern) do
      case Regex.compile(pattern, "u") do
        {:ok, regex} ->
          %{type | pattern_regex: regex}

        {:error, {reason, _position}} ->
          provider_type_error!(
            provider,
            module,
            function,
            args,
            "pattern #{inspect(pattern)} does not compile: #{reason}"
          )
      end
    else
      provider_type_error!(
        provider,
        module,
        function,
        args,
        "pattern must be valid UTF-8, got: #{inspect(pattern)}"
      )
    end
  end

  defp validate_pattern!(%Type{pattern: pattern}, provider, module, function, args) do
    provider_type_error!(
      provider,
      module,
      function,
      args,
      "pattern must be a string, got: #{inspect(pattern)}"
    )
  end

  defp validate_transform!(
         %Type{transform: nil},
         _provider,
         _module,
         _function,
         _args
       ),
       do: :ok

  defp validate_transform!(
         %Type{transform: {module, function}},
         _provider,
         _remote,
         _fun,
         _args
       )
       when is_atom(module) and is_atom(function),
       do: :ok

  defp validate_transform!(%Type{transform: transform}, provider, module, function, args) do
    provider_type_error!(
      provider,
      module,
      function,
      args,
      "transform must be nil or {module, function}, got: #{inspect(transform)}"
    )
  end

  defp validate_metadata!(%Type{} = type, provider, module, function, args) do
    validate_bounds!(type, provider, module, function, args)
    validate_format!(type, provider, module, function, args)
    validate_nullable!(type, provider, module, function, args)
    validate_values!(type, provider, module, function, args)
    type
  end

  defp validate_bounds!(
         %Type{kind: kind, minimum: minimum, maximum: maximum} = type,
         provider,
         module,
         function,
         args
       ) do
    validate_bound!(kind, minimum, "minimum", provider, module, function, args)
    validate_bound!(kind, maximum, "maximum", provider, module, function, args)
    validate_bound_order!(minimum, maximum, provider, module, function, args)
    validate_array_bound!(kind, minimum, "minimum", provider, module, function, args)
    validate_array_bound!(kind, maximum, "maximum", provider, module, function, args)
    type
  end

  defp validate_bound!(_kind, nil, _name, _provider, _module, _function, _args), do: :ok

  defp validate_bound!(:array, value, _name, _provider, _module, _function, _args)
       when is_integer(value),
       do: :ok

  defp validate_bound!(:array, value, name, provider, module, function, args) do
    provider_type_error!(
      provider,
      module,
      function,
      args,
      "array #{name} must be an integer or nil, got: #{inspect(value)}"
    )
  end

  defp validate_bound!(_kind, value, _name, _provider, _module, _function, _args)
       when is_number(value),
       do: :ok

  defp validate_bound!(_kind, value, name, provider, module, function, args) do
    provider_type_error!(
      provider,
      module,
      function,
      args,
      "#{name} must be a number or nil, got: #{inspect(value)}"
    )
  end

  defp validate_bound_order!(
         minimum,
         maximum,
         provider,
         module,
         function,
         args
       )
       when is_number(minimum) and is_number(maximum) and minimum > maximum do
    provider_type_error!(
      provider,
      module,
      function,
      args,
      "minimum must be <= maximum, got: #{inspect(minimum)} > #{inspect(maximum)}"
    )
  end

  defp validate_bound_order!(_minimum, _maximum, _provider, _module, _function, _args),
    do: :ok

  defp validate_array_bound!(:array, value, name, provider, module, function, args)
       when is_integer(value) and value < 0 do
    provider_type_error!(
      provider,
      module,
      function,
      args,
      "array #{name} must be >= 0, got: #{inspect(value)}"
    )
  end

  defp validate_array_bound!(_kind, _value, _name, _provider, _module, _function, _args),
    do: :ok

  defp validate_format!(%Type{format: nil}, _provider, _module, _function, _args), do: :ok

  defp validate_format!(%Type{format: format}, provider, module, function, args)
       when is_binary(format) do
    if String.valid?(format) do
      :ok
    else
      provider_type_error!(
        provider,
        module,
        function,
        args,
        "format must be valid UTF-8, got: #{inspect(format)}"
      )
    end
  end

  defp validate_format!(%Type{format: format}, provider, module, function, args) do
    provider_type_error!(
      provider,
      module,
      function,
      args,
      "format must be a string or nil, got: #{inspect(format)}"
    )
  end

  defp validate_nullable!(%Type{nullable: nullable}, _provider, _module, _function, _args)
       when is_boolean(nullable),
       do: :ok

  defp validate_nullable!(%Type{nullable: nullable}, provider, module, function, args) do
    provider_type_error!(
      provider,
      module,
      function,
      args,
      "nullable must be a boolean, got: #{inspect(nullable)}"
    )
  end

  defp validate_values!(%Type{kind: :enum, values: nil}, _provider, _module, _function, _args),
    do: :ok

  defp validate_values!(%Type{kind: :enum, values: values}, provider, module, function, args)
       when is_list(values) do
    Enum.each(values, &validate_enum_value!(&1, provider, module, function, args))
  end

  defp validate_values!(%Type{kind: :enum, values: values}, provider, module, function, args) do
    provider_type_error!(
      provider,
      module,
      function,
      args,
      "values must be a list or nil, got: #{inspect(values)}"
    )
  end

  defp validate_values!(%Type{}, _provider, _module, _function, _args), do: :ok

  defp validate_enum_value!(value, provider, module, function, args) when is_binary(value) do
    if String.valid?(value) do
      :ok
    else
      provider_type_error!(
        provider,
        module,
        function,
        args,
        "enum values must be valid UTF-8, got: #{inspect(value)}"
      )
    end
  end

  defp validate_enum_value!(value, _provider, _module, _function, _args)
       when is_number(value) or is_boolean(value) or is_atom(value),
       do: :ok

  defp validate_enum_value!(value, provider, module, function, args) do
    provider_type_error!(
      provider,
      module,
      function,
      args,
      "enum values must be JSON scalars, got: #{inspect(value)}"
    )
  end

  defp validate_children!(%Type{} = type, provider, module, function, args) do
    type
    |> validate_items!(provider, module, function, args)
    |> validate_fields!(provider, module, function, args)
    |> validate_additional!(provider, module, function, args)
    |> validate_variants!(provider, module, function, args)
  end

  defp validate_items!(
         %Type{kind: :array, items: nil} = type,
         _provider,
         _module,
         _function,
         _args
       ),
       do: type

  defp validate_items!(
         %Type{kind: :array, items: %Type{} = items} = type,
         provider,
         module,
         function,
         args
       ) do
    %{type | items: validate_provider_type!(items, provider, module, function, args)}
  end

  defp validate_items!(%Type{kind: :array, items: items}, provider, module, function, args),
    do: invalid_child!(provider, module, function, args, "items", items)

  defp validate_items!(
         %Type{kind: :tuple, items: nil} = type,
         _provider,
         _module,
         _function,
         _args
       ),
       do: type

  defp validate_items!(
         %Type{kind: :tuple, items: items} = type,
         provider,
         module,
         function,
         args
       )
       when is_list(items) do
    %{type | items: validate_type_list!(items, provider, module, function, args)}
  end

  defp validate_items!(%Type{kind: :tuple, items: items}, provider, module, function, args),
    do: invalid_child!(provider, module, function, args, "items", items)

  defp validate_items!(%Type{} = type, _provider, _module, _function, _args), do: type

  defp validate_fields!(
         %Type{kind: :object, fields: nil} = type,
         _provider,
         _module,
         _function,
         _args
       ),
       do: type

  defp validate_fields!(
         %Type{kind: :object, fields: fields} = type,
         provider,
         module,
         function,
         args
       )
       when is_list(fields) do
    fields =
      Enum.map(fields, fn
        %Field{type: %Type{} = field_type, name: name, key: key, required: required} = field
        when is_binary(name) and is_atom(key) and is_boolean(required) ->
          validate_name!(name, "field")
          %{field | type: validate_provider_type!(field_type, provider, module, function, args)}

        other ->
          provider_type_error!(
            provider,
            module,
            function,
            args,
            "field must have a string name, atom key, boolean required and ToolCall.IR.Type, " <>
              "got: #{inspect(other)}"
          )
      end)

    validate_unique_fields!(fields)
    %{type | fields: fields}
  end

  defp validate_fields!(%Type{kind: :object, fields: fields}, provider, module, function, args),
    do: invalid_child!(provider, module, function, args, "fields", fields)

  defp validate_fields!(%Type{} = type, _provider, _module, _function, _args), do: type

  defp validate_unique_fields!(fields) do
    duplicate_names = fields |> Enum.map(& &1.name) |> duplicate_values()
    duplicate_keys = fields |> Enum.map(& &1.key) |> Enum.reject(&is_nil/1) |> duplicate_values()

    cond do
      duplicate_names != [] ->
        raise ArgumentError,
              "invalid ToolCall IR: duplicate field names #{inspect(duplicate_names)}"

      duplicate_keys != [] ->
        raise ArgumentError,
              "invalid ToolCall IR: duplicate field keys #{inspect(duplicate_keys)}"

      true ->
        :ok
    end
  end

  defp validate_additional!(
         %Type{kind: :object, additional: nil} = type,
         _provider,
         _module,
         _function,
         _args
       ),
       do: type

  defp validate_additional!(
         %Type{kind: :object, additional: %Type{} = additional} = type,
         provider,
         module,
         function,
         args
       ) do
    %{type | additional: validate_provider_type!(additional, provider, module, function, args)}
  end

  defp validate_additional!(
         %Type{kind: :object, additional: additional},
         provider,
         module,
         function,
         args
       ),
       do: invalid_child!(provider, module, function, args, "additional", additional)

  defp validate_additional!(%Type{} = type, _provider, _module, _function, _args), do: type

  defp validate_variants!(
         %Type{kind: :union, variants: []} = type,
         provider,
         module,
         function,
         args
       ) do
    if type.nullable do
      type
    else
      invalid_child!(provider, module, function, args, "variants", [])
    end
  end

  defp validate_variants!(
         %Type{kind: :union, variants: variants} = type,
         provider,
         module,
         function,
         args
       )
       when is_list(variants) do
    %{type | variants: validate_type_list!(variants, provider, module, function, args)}
  end

  defp validate_variants!(
         %Type{kind: :union, variants: variants},
         provider,
         module,
         function,
         args
       ),
       do: invalid_child!(provider, module, function, args, "variants", variants)

  defp validate_variants!(%Type{} = type, _provider, _module, _function, _args), do: type

  defp validate_type_list!(types, provider, module, function, args) do
    Enum.map(types, fn
      %Type{} = type -> validate_provider_type!(type, provider, module, function, args)
      other -> invalid_child!(provider, module, function, args, "nested type", other)
    end)
  end

  @spec invalid_child!(
          module() | nil,
          module() | nil,
          atom() | nil,
          list() | nil,
          String.t(),
          term()
        ) ::
          no_return()
  defp invalid_child!(provider, module, function, args, field, value) do
    provider_type_error!(
      provider,
      module,
      function,
      args,
      "#{field} must contain ToolCall.IR types, got: #{inspect(value)}"
    )
  end

  @spec provider_type_error!(
          module() | nil,
          module() | nil,
          atom() | nil,
          list() | nil,
          String.t()
        ) :: no_return()
  defp provider_type_error!(nil, _module, _function, _args, reason) do
    raise ArgumentError, "invalid ToolCall IR: #{reason}"
  end

  defp provider_type_error!(provider, module, function, args, reason) do
    raise ArgumentError,
          "type provider #{inspect(provider)} returned an invalid type for " <>
            "#{inspect(module)}.#{function}/#{length(args)}: #{reason}"
  end

  @doc """
  Validates a runtime `ToolCall.IR.Type` and returns a copy with compiled
  `pattern_regex`.

  Use this for hand-built types before passing them to `ToolCall.Coerce` or
  rendering them with `ToolCall.Emit`.
  """
  @spec validate_type!(Type.t()) :: Type.t()
  def validate_type!(%Type{} = type) do
    validate_provider_type!(type, nil, nil, nil, nil)
  end

  def validate_type!(other) do
    raise ArgumentError, "invalid ToolCall IR: expected a type, got: #{inspect(other)}"
  end

  @doc """
  Validates a runtime `ToolCall.IR.Tool` and returns a copy with prepared
  parameters.

  Parameter types are validated through `validate_type!/1`, so hand-built
  patterns receive a compiled `pattern_regex`; tool and parameter metadata are
  checked as well.
  """
  @spec validate_tool!(Tool.t()) :: Tool.t()
  def validate_tool!(%Tool{name: name, description: description, params: params} = tool)
      when is_binary(name) do
    validate_name!(name, "tool")
    validate_description!(description, "tool")
    defs = validate_defs!(tool.defs || %{})
    params = Enum.map(params || [], &prepare_param!/1)
    validate_unique_params!(params)
    validate_refs!(params, defs)
    %{tool | params: params, defs: defs}
  end

  def validate_tool!(%Tool{} = tool) do
    raise ArgumentError,
          "invalid ToolCall IR: tool name must be a string, got: #{inspect(tool.name)}"
  end

  def validate_tool!(other) do
    raise ArgumentError, "invalid ToolCall IR: expected a tool, got: #{inspect(other)}"
  end

  defp prepare_param!(
         %Param{
           name: name,
           type: type,
           wire: wire,
           required: required,
           description: description,
           default: default
         } = param
       )
       when is_binary(name) and wire in [:number, :string_integer] and is_boolean(required) do
    validate_name!(name, "parameter")
    validate_description!(description, "parameter")
    type = validate_type!(type)
    validate_wire!(wire, type, name)
    validate_default!(default, type)
    %{param | type: type}
  end

  defp prepare_param!(other) do
    raise ArgumentError, "invalid ToolCall IR: invalid parameter #{inspect(other)}"
  end

  defp validate_wire!(:number, _type, _name), do: :ok

  defp validate_wire!(:string_integer, %Type{kind: :integer}, _name), do: :ok

  defp validate_wire!(:string_integer, %Type{kind: kind}, name) do
    raise ArgumentError,
          "invalid ToolCall IR: wire :string_integer requires an integer parameter, " <>
            "got #{inspect(kind)} for #{inspect(name)}"
  end

  defp validate_ref!(%Type{kind: :ref} = type, provider, _module, _function, _args) do
    cond do
      provider != nil ->
        raise ArgumentError, "type provider #{inspect(provider)} cannot return a ref"

      is_binary(type.ref) and type.ref != "" ->
        type

      true ->
        provider_type_error!(
          nil,
          nil,
          nil,
          nil,
          "ref must be a non-empty string, got: #{inspect(type.ref)}"
        )
    end
  end

  defp validate_ref!(type, _provider, _module, _function, _args), do: type

  defp validate_defs!(defs) when is_map(defs) do
    Enum.reduce(defs, %{}, fn
      {name, %Type{} = type}, acc when is_binary(name) and name != "" ->
        Map.put(acc, name, validate_type!(type))

      {name, other}, _acc ->
        raise ArgumentError,
              "invalid ToolCall IR: invalid $defs entry #{inspect(name)}, got: #{inspect(other)}"
    end)
  end

  defp validate_defs!(other) do
    raise ArgumentError, "invalid ToolCall IR: defs must be a map, got: #{inspect(other)}"
  end

  defp validate_refs!(params, defs) do
    refs =
      Enum.flat_map(params, &type_refs(&1.type)) ++
        Enum.flat_map(Map.values(defs), &type_refs/1)

    case Enum.reject(refs, &Map.has_key?(defs, &1)) do
      [] ->
        :ok

      [missing | _rest] ->
        raise ArgumentError,
              "invalid ToolCall IR: unknown $defs entry #{inspect(missing)}"
    end
  end

  defp type_refs(%Type{kind: :ref, ref: ref}), do: [ref]
  defp type_refs(%Type{kind: :array, items: items}), do: type_refs(items)

  defp type_refs(%Type{kind: :tuple, items: items}),
    do: Enum.flat_map(items || [], &type_refs/1)

  defp type_refs(%Type{kind: :union, variants: variants}),
    do: Enum.flat_map(variants || [], &type_refs/1)

  defp type_refs(%Type{kind: :object, fields: fields, additional: additional}) do
    Enum.flat_map(fields || [], &type_refs(&1.type)) ++ type_refs(additional)
  end

  defp type_refs(nil), do: []
  defp type_refs(%Type{}), do: []

  defp validate_unique_params!(params) do
    params
    |> Enum.map(& &1.name)
    |> duplicate_values()
    |> case do
      [] ->
        :ok

      names ->
        raise ArgumentError,
              "invalid ToolCall IR: duplicate parameter names #{inspect(names)}"
    end
  end

  defp duplicate_values(values) do
    values
    |> Enum.frequencies()
    |> Enum.filter(fn {_value, count} -> count > 1 end)
    |> Enum.map(&elem(&1, 0))
  end

  defp validate_name!(name, owner) do
    if String.valid?(name) do
      :ok
    else
      raise ArgumentError,
            "invalid ToolCall IR: #{owner} name must be valid UTF-8, got: #{inspect(name)}"
    end
  end

  defp validate_description!(nil, _owner), do: :ok

  defp validate_description!(description, _owner) when is_binary(description) do
    if String.valid?(description) do
      :ok
    else
      raise ArgumentError,
            "invalid ToolCall IR: description must be valid UTF-8, got: #{inspect(description)}"
    end
  end

  defp validate_description!(description, owner) do
    raise ArgumentError,
          "invalid ToolCall IR: #{owner} description must be a string or nil, " <>
            "got: #{inspect(description)}"
  end

  defp validate_default!(nil, _type), do: :ok

  defp validate_default!(default, type) do
    cond do
      not json_value?(default) ->
        raise ArgumentError,
              "invalid ToolCall IR: default must be JSON-encodable, got: #{inspect(default)}"

      not default_compatible?(type, default) ->
        raise ArgumentError,
              "invalid ToolCall IR: default #{inspect(default)} is not compatible with " <>
                "type #{inspect(Map.get(type, :kind))}"

      true ->
        :ok
    end
  end

  @doc false
  @spec default_compatible?(Type.t(), term()) :: boolean()
  def default_compatible?(%Type{kind: :object, source: :keyword} = type, value)
      when is_map(value) do
    additional = type.additional || %Type{kind: :any}

    Enum.all?(value, fn
      {key, item} when is_atom(key) -> default_compatible?(additional, item)
      _other -> false
    end)
  end

  def default_compatible?(%Type{transform: transform}, _value) when not is_nil(transform),
    do: true

  def default_compatible?(%Type{kind: :atom}, nil), do: false
  def default_compatible?(%Type{nullable: true}, nil), do: true

  def default_compatible?(%Type{kind: :integer} = type, value) when is_integer(value),
    do: within_bounds?(type, value)

  def default_compatible?(%Type{kind: :float} = type, value) when is_float(value),
    do: within_bounds?(type, value)

  def default_compatible?(%Type{kind: :number} = type, value) when is_number(value),
    do: within_bounds?(type, value)

  def default_compatible?(%Type{kind: :string, source: :char}, value) when is_integer(value),
    do: value >= 0 and value <= 0x10FFFF

  def default_compatible?(%Type{kind: :string, source: :char}, value) when is_binary(value),
    do: String.valid?(value) and String.length(value) == 1

  def default_compatible?(%Type{kind: :string, source: :charlist}, value) when is_list(value) do
    is_binary(List.to_string(value))
  rescue
    _exception -> false
  end

  def default_compatible?(%Type{kind: :string, source: :charlist}, value) when is_binary(value),
    do: String.valid?(value)

  def default_compatible?(%Type{kind: :string, source: :charlist}, _value), do: false

  def default_compatible?(%Type{kind: :string} = type, value) when is_binary(value) do
    String.valid?(value) and default_pattern?(type, value)
  end

  def default_compatible?(%Type{kind: :boolean}, value), do: is_boolean(value)

  def default_compatible?(%Type{kind: :atom}, value),
    do: is_atom(value) and not is_boolean(value)

  def default_compatible?(%Type{kind: :null}, nil), do: true

  def default_compatible?(%Type{kind: :enum, values: values}, value) when is_list(values),
    do: value in values

  def default_compatible?(%Type{kind: :array} = type, value) when is_list(value) do
    items = type.items || %Type{kind: :any}
    within_bounds?(type, length(value)) and Enum.all?(value, &default_compatible?(items, &1))
  end

  def default_compatible?(%Type{kind: :tuple, items: nil}, value)
      when is_list(value) or is_tuple(value),
      do: true

  def default_compatible?(%Type{kind: :tuple, items: items}, value)
      when is_list(value) or is_tuple(value) do
    values = if is_tuple(value), do: Tuple.to_list(value), else: value

    is_list(items) and
      length(values) == length(items) and
      items
      |> Enum.zip(values)
      |> Enum.all?(fn {type, item} -> default_compatible?(type, item) end)
  end

  def default_compatible?(%Type{kind: :object} = type, value) when is_map(value) do
    fields = type.fields || []

    Enum.all?(fields, &default_field_compatible?(&1, value)) and
      default_extra_compatible?(type, fields, value)
  end

  def default_compatible?(%Type{kind: :any}, _value), do: true

  def default_compatible?(%Type{kind: :union} = type, value) do
    Enum.any?(type.variants || [], &default_compatible?(&1, value))
  end

  def default_compatible?(%Type{}, _value), do: false

  defp default_field_compatible?(%Field{required: required, type: type} = field, value) do
    case default_field_value(value, field) do
      {:ok, field_value} -> default_compatible?(type, field_value)
      :error -> not required
    end
  end

  defp default_field_value(value, %Field{key: key, name: name}) do
    cond do
      not is_nil(key) and Map.has_key?(value, key) -> {:ok, Map.fetch!(value, key)}
      Map.has_key?(value, name) -> {:ok, Map.fetch!(value, name)}
      true -> :error
    end
  end

  defp default_extra_compatible?(%Type{additional: nil}, fields, value) do
    Enum.all?(value, fn {key, _value} -> Enum.any?(fields, &default_field_key?(&1, key)) end)
  end

  defp default_extra_compatible?(%Type{additional: %Type{} = additional}, fields, value) do
    value
    |> Enum.reject(fn {key, _value} -> Enum.any?(fields, &default_field_key?(&1, key)) end)
    |> Enum.all?(fn {_key, extra} -> default_compatible?(additional, extra) end)
  end

  defp default_extra_compatible?(%Type{}, _fields, _value), do: false

  defp default_field_key?(%Field{key: nil, name: name}, key), do: key == name

  defp default_field_key?(%Field{key: field_key, name: name}, key),
    do: key == field_key or key == name

  defp within_bounds?(%Type{} = type, value) do
    minimum = type.minimum
    maximum = type.maximum

    (is_nil(minimum) or value >= minimum) and (is_nil(maximum) or value <= maximum)
  end

  defp default_pattern?(%Type{pattern: nil}, _value), do: true

  defp default_pattern?(%Type{pattern_regex: %Regex{} = regex}, value),
    do: Regex.match?(regex, value)

  defp default_pattern?(%Type{pattern: pattern}, value) when is_binary(pattern) do
    case Regex.compile(pattern, "u") do
      {:ok, regex} -> Regex.match?(regex, value)
      {:error, _reason} -> false
    end
  end

  defp default_pattern?(%Type{}, _value), do: false

  defp json_value?(value)
       when is_nil(value) or is_boolean(value) or is_atom(value) or is_number(value),
       do: true

  defp json_value?(value) when is_binary(value), do: String.valid?(value)

  defp json_value?(value) when is_list(value), do: Enum.all?(value, &json_value?/1)

  defp json_value?(value) when is_map(value) and not is_struct(value) do
    Enum.all?(value, fn {key, item} ->
      (is_atom(key) or (is_binary(key) and String.valid?(key))) and json_value?(item)
    end)
  end

  defp json_value?(_value), do: false

  @doc """
  True when the tree contains a domain JSON cannot represent at all.

  `:any` is not unrepresentable: it means "unknown", and JSON can carry any
  value for it. Only `:unsupported` (functions, pids, refs) is.
  """
  @spec unrepresentable?(Type.t()) :: boolean()
  def unrepresentable?(%Type{kind: kind}) when kind in [:unsupported], do: true
  def unrepresentable?(%Type{kind: :array, items: items}), do: unrepresentable?(items)

  def unrepresentable?(%Type{kind: :tuple, items: items}),
    do: Enum.any?(items || [], &unrepresentable?/1)

  def unrepresentable?(%Type{kind: :union, variants: variants}),
    do: Enum.any?(variants || [], &unrepresentable?/1)

  def unrepresentable?(%Type{kind: :object, fields: fields, additional: additional}) do
    Enum.any?(fields || [], &unrepresentable?(&1.type)) or unrepresentable?(additional)
  end

  def unrepresentable?(nil), do: false
  def unrepresentable?(%Type{}), do: false

  @doc """
  True when the tree contains an object whose keys the spec does not fix.

  Strict mode closes every object with `additionalProperties: false`, so an open
  one reaches the model as an object that accepts no key at all.
  """
  @spec open_object?(Type.t() | nil) :: boolean()
  def open_object?(%Type{kind: :object} = type) do
    not is_nil(type.additional) or Enum.any?(type.fields || [], &open_object?(&1.type))
  end

  def open_object?(%Type{kind: :array, items: items}), do: open_object?(items)
  def open_object?(%Type{kind: :tuple, items: items}), do: Enum.any?(items || [], &open_object?/1)

  def open_object?(%Type{kind: :union, variants: variants}),
    do: Enum.any?(variants || [], &open_object?/1)

  def open_object?(_type), do: false

  @doc """
  True when the tree contains a tuple, which strict mode cannot express.

  OpenAI rejects `prefixItems`, so the emitter can only keep the arity.
  """
  @spec tuple?(Type.t() | nil) :: boolean()
  def tuple?(%Type{kind: :tuple}), do: true
  def tuple?(%Type{kind: :array, items: items}), do: tuple?(items)
  def tuple?(%Type{kind: :union, variants: variants}), do: Enum.any?(variants || [], &tuple?/1)

  def tuple?(%Type{kind: :object} = type),
    do: Enum.any?(type.fields || [], &tuple?(&1.type)) or tuple?(type.additional)

  def tuple?(_type), do: false

  @doc """
  True when the tree has no JSON type the model can constrain against.

  This is broader than `unrepresentable?/1`: `:any` and open objects do have a
  JSON encoding, but they cannot be typed in the strict schema subset.
  """
  @spec untyped?(Type.t() | nil) :: boolean()
  def untyped?(%Type{kind: kind}) when kind in [:any, :unsupported], do: true
  def untyped?(%Type{kind: :array, items: items}), do: untyped?(items)
  def untyped?(%Type{kind: :tuple, items: items}), do: Enum.any?(items || [], &untyped?/1)

  def untyped?(%Type{kind: :union, variants: variants}),
    do: Enum.any?(variants || [], &untyped?/1)

  def untyped?(%Type{kind: :object} = type) do
    Enum.any?(type.fields || [], &untyped?(&1.type)) or untyped?(type.additional)
  end

  def untyped?(%Type{kind: :struct}), do: true
  def untyped?(nil), do: false
  def untyped?(%Type{}), do: false
  # --- helpers --------------------------------------------------------------

  defp int_literal(int) when is_integer(int), do: {:ok, int}
  defp int_literal({:-, _, [int]}) when is_integer(int), do: {:ok, -int}
  defp int_literal(_other), do: :error

  defp flatten_union({:|, _, [left, right]}, providers) do
    flatten_union(left, providers) ++ flatten_union(right, providers)
  end

  defp flatten_union(other, providers), do: [to_type(other, providers)]

  defp build_union(variants) do
    {nulls, rest} = Enum.split_with(variants, &(&1.kind == :null))
    {singletons, rest} = Enum.split_with(rest, &singleton?/1)
    nullable? = nulls != []

    cond do
      rest == [] and singletons != [] -> union_enum(singletons, nullable?)
      singletons == [] and match?([_], rest) -> union_single(rest, nullable?)
      singletons == [] and same_kind?(rest) -> union_merged(rest, nullable?)
      true -> union_mixed(rest, singletons, nullable?)
    end
  end

  defp union_enum(singletons, nullable?) do
    %Type{kind: :enum, values: Enum.map(singletons, &singleton_value/1), nullable: nullable?}
  end

  defp union_single([type], nullable?) do
    %{type | nullable: nullable? or type.nullable}
  end

  defp union_merged(rest, nullable?) do
    case merge_same_kind_list(rest) do
      {:ok, merged} -> %{merged | nullable: nullable? or merged.nullable}
      :error -> union_mixed(rest, [], nullable?)
    end
  end

  defp union_mixed(rest, singletons, nullable?) do
    variants = if singletons == [], do: rest, else: rest ++ [union_enum(singletons, false)]
    %Type{kind: :union, variants: Enum.uniq_by(variants, &signature/1), nullable: nullable?}
  end

  defp same_kind?([]), do: false
  defp same_kind?(variants), do: variants |> Enum.map(& &1.kind) |> Enum.uniq() |> length() == 1

  # Only kinds that carry no structure collapse safely. Anything else keeps its
  # variants: merging `[integer()] | [string()]` into the first array would drop
  # a whole branch of the value domain.
  @scalar_kinds [:float, :number, :boolean, :atom, :null, :any]

  defp merge_same_kind_list([%Type{kind: :integer} | _] = variants),
    do: merge_integer_ranges(variants)

  defp merge_same_kind_list([%Type{kind: kind} | _] = variants) when kind in @scalar_kinds,
    do: {:ok, hd(variants)}

  defp merge_same_kind_list(_variants), do: :error

  # The union of two integer domains is representable as one interval only when
  # the intervals overlap or touch. `nil` bounds are infinities: any variant
  # that is unbounded on a side must keep the union unbounded on that side.
  defp merge_integer_ranges(variants) do
    bounds =
      variants
      |> Enum.map(&{&1.minimum, &1.maximum})
      |> Enum.sort_by(fn {low, _high} -> {low != nil, low || 0} end)
      |> coalesce()

    case bounds do
      [{minimum, maximum}] -> {:ok, %Type{kind: :integer, minimum: minimum, maximum: maximum}}
      _gaps -> :error
    end
  end

  defp coalesce(intervals) do
    intervals
    |> Enum.reduce([], &insert_interval/2)
    |> Enum.reverse()
  end

  defp insert_interval(interval, []), do: [interval]

  defp insert_interval(interval, [current | rest] = acc) do
    if touches?(current, interval),
      do: [widen(current, interval) | rest],
      else: [interval | acc]
  end

  defp touches?({_low, high}, {next_low, _high}) when is_nil(high) or is_nil(next_low), do: true
  defp touches?({_low, high}, {next_low, _high}), do: next_low <= high + 1

  defp widen({low, high}, {next_low, next_high}) do
    {if(is_nil(low) or is_nil(next_low), do: nil, else: min(low, next_low)),
     if(is_nil(high) or is_nil(next_high), do: nil, else: max(high, next_high))}
  end

  # Structural equality, without the provenance the schema never uses.
  defp signature(%Type{} = type), do: %{type | source: nil, nullable: false}

  defp singleton?(%Type{kind: :enum, values: [_ | _]}), do: true

  defp singleton?(%Type{kind: :integer, minimum: same, maximum: same}) when not is_nil(same),
    do: true

  defp singleton?(_), do: false

  defp singleton_value(%Type{kind: :enum, values: [value]}), do: value
  defp singleton_value(%Type{kind: :integer, minimum: value}), do: value

  defp build_object(pairs, providers) do
    {fields, additional} =
      Enum.reduce(pairs, {[], nil}, fn
        {{:required, _, [key]}, type}, {fields, additional} when is_atom(key) ->
          {[field(key, type, true, providers) | fields], additional}

        {{:optional, _, [key]}, type}, {fields, additional} when is_atom(key) ->
          {[field(key, type, false, providers) | fields], additional}

        {key, type}, {fields, additional} when is_atom(key) ->
          {[field(key, type, true, providers) | fields], additional}

        {_key_type, type}, {fields, _additional} ->
          {fields, to_type(type, providers)}
      end)

    %Type{kind: :object, fields: Enum.reverse(fields), additional: additional}
  end

  defp field(key, type, required?, providers) do
    %Field{
      name: Atom.to_string(key),
      key: key,
      type: to_type(type, providers),
      required: required?
    }
  end
end
