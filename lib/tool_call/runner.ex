defmodule ToolCall.Runner do
  @moduledoc """
  Validates and dispatches a decoded argument map to the tool function.

  Validation is generated from the same IR that produced the schema, so the
  parameter set, its names and its types cannot drift between the two.
  """

  require Logger

  alias ToolCall.{Coerce, Typespec, Validate}
  alias ToolCall.IR.{Param, Tool, Type}

  @option_keys [
    :validate_result,
    :timeout,
    :timeout_policy,
    :task_supervisor,
    :approval,
    :audit,
    :context
  ]

  @doc """
  Runs a tool by name.

  `args` uses string keys, as JSON decodes them, including nested object values;
  `keyword(t)` values also accept atom keys because a keyword list is their value
  domain. Invalid UTF-8 binaries in string arguments become
  `{:invalid_argument, {name, {:invalid_utf8, value}}}` errors.

  Runtime tool lists are validated before dispatch. Compiled tools can use
  `run_prepared/4` to skip that validation.
  """
  @spec run(module(), [Tool.t()], atom() | String.t(), term(), keyword()) ::
          {:ok, term()} | {:pending, ToolCall.Approval.Request.t()} | {:error, term()}
  def run(module, tools, name, args, opts \\ [])

  def run(module, tools, name, args, opts) when is_map(args) do
    validate_options!(opts)

    tools =
      with_audit(module, audit_tool_name(name), args, opts, Keyword.get(opts, :context), fn ->
        Enum.map(tools, &Typespec.validate_tool!/1)
      end)

    run_prepared(module, tools, name, args, opts)
  end

  def run(module, _tools, name, args, opts) do
    validate_options!(opts)

    audit_failure(
      module,
      audit_tool_name(name),
      args,
      opts,
      :invalid_arguments,
      {:invalid_arguments, args},
      0
    )

    {:error, {:invalid_arguments, args}}
  end

  @doc """
  Internal fast path for already prepared tools.

  This skips runtime IR validation. Callers must pass tools prepared by
  `ToolCall.Typespec.validate_tool!/1`; use `run/4` for arbitrary runtime tools.
  """
  @spec run_prepared(module(), [Tool.t()], atom() | String.t(), term(), keyword()) ::
          {:ok, term()} | {:pending, ToolCall.Approval.Request.t()} | {:error, term()}
  def run_prepared(module, tools, name, args, opts \\ [])

  def run_prepared(module, tools, name, args, opts) when is_map(args) do
    validate_options!(opts)
    name = to_string(name)

    case fetch(tools, name) do
      {:ok, tool} ->
        run_prepared_tool(module, tool, args, true, nil, opts)

      error ->
        audit_failure(module, name, args, opts, :unknown_tool, nil, 0)
        error
    end
  end

  def run_prepared(module, _tools, name, args, opts) do
    validate_options!(opts)

    audit_failure(
      module,
      audit_tool_name(name),
      args,
      opts,
      :invalid_arguments,
      {:invalid_arguments, args},
      0
    )

    {:error, {:invalid_arguments, args}}
  end

  @doc false
  @spec run_prepared_tool(module(), Tool.t(), term()) ::
          {:ok, term()} | {:pending, ToolCall.Approval.Request.t()} | {:error, term()}
  def run_prepared_tool(module, %Tool{} = tool, args) do
    run_prepared_tool(module, tool, args, true, nil, [])
  end

  @doc false
  @spec run_prepared_tool(module(), Tool.t(), term(), boolean(), [String.t()] | nil) ::
          {:ok, term()} | {:pending, ToolCall.Approval.Request.t()} | {:error, term()}
  def run_prepared_tool(module, %Tool{} = tool, args, check_nested?, known) do
    run_prepared_tool(module, tool, args, check_nested?, known, [])
  end

  @doc false
  @spec run_prepared_tool(module(), Tool.t(), term(), boolean(), [String.t()] | nil, keyword()) ::
          {:ok, term()} | {:pending, ToolCall.Approval.Request.t()} | {:error, term()}
  def run_prepared_tool(module, %Tool{} = tool, args, check_nested?, known, opts)
      when is_map(args) do
    validate_options!(opts)
    context = Keyword.get(opts, :context)

    with_audit(module, tool.name, args, opts, context, fn ->
      {duration, resolved} =
        :timer.tc(fn -> resolve_tool(module, tool, args, check_nested?, known, opts) end)

      case resolved do
        {:ok, call} ->
          execute_unguarded(call, opts)

        {:error, reason} = error ->
          audit_failure(module, tool.name, args, opts, :invalid_arguments, reason, duration)
          error
      end
    end)
  end

  def run_prepared_tool(module, %Tool{} = tool, args, _check_nested?, _known, opts) do
    validate_options!(opts)

    audit_failure(
      module,
      tool.name,
      args,
      opts,
      :invalid_arguments,
      {:invalid_arguments, args},
      0
    )

    {:error, {:invalid_arguments, args}}
  end

  @doc """
  Resolves a tool call without invoking it.

  Runs the key checks, coercion and positional construction and answers a
  `ToolCall.Call` that `execute/2` can run later. The tool is not invoked.
  The module's timeout default, the caller's `:timeout` or an optional
  `ToolCall.Timeout` policy is stored in the call; a policy is evaluated by
  `execute/2`, after approval. `:context` is stored for the approval, audit and
  timeout policies. Module-level timeout, approval and audit policies are
  loaded on demand. A hand-built tool is validated first; invalid IR raises
  `ArgumentError`.
  """
  @spec resolve(module(), Tool.t(), map(), keyword()) ::
          {:ok, ToolCall.Call.t()} | {:error, term()}
  def resolve(module, tool, args, opts \\ [])

  def resolve(module, %Tool{} = tool, args, opts) when is_map(args) do
    validate_options!(opts)
    resolve_tool(module, Typespec.validate_tool!(tool), args, true, nil, opts)
  end

  def resolve(_module, %Tool{}, args, opts) do
    validate_options!(opts)
    {:error, {:invalid_arguments, args}}
  end

  @doc """
  Executes a call produced by `resolve/4`.

  The call's timeout applies unless `:timeout` is given. A stored timeout
  policy is evaluated here, after the approval check, with the call's raw `args`
  and the effective context. `:task_supervisor` is passed to
  `ToolCall.Timeout.run/3`. The stored approval policy is checked unless
  `:approval` overrides it; a `{:required, reason}` answer returns
  `{:pending, %ToolCall.Approval.Request{}}` without invoking. The call's
  `context` (set by `resolve/4`) is passed to the policies unless `:context`
  overrides it.
  """
  @spec execute(ToolCall.Call.t(), keyword()) ::
          {:ok, term()} | {:pending, ToolCall.Approval.Request.t()} | {:error, term()}
  def execute(%ToolCall.Call{} = call, opts \\ []) do
    validate_options!(opts)
    context = Keyword.get(opts, :context, call.context)

    with_audit(call.module, call.tool.name, call.args, opts, context, fn ->
      execute_unguarded(call, opts)
    end)
  end

  defp execute_unguarded(call, opts) do
    audit = Keyword.get(opts, :audit, call.audit)
    context = Keyword.get(opts, :context, call.context)
    validate_static_timeout!(call, opts)

    {duration, {outcome, result}} = :timer.tc(fn -> dispatch(call, opts, context) end)
    record_audit(audit, call, outcome, result, duration, context)
    result
  end

  defp dispatch(call, opts, context) do
    approval = Keyword.get(opts, :approval, call.approval)

    case approve(call, approval, context) do
      :ok ->
        case effective_timeout(call, opts, context) do
          {:ok, timeout} ->
            dispatch_timeout(call, opts, timeout)

          {:error, reason} ->
            {:error, {:error, reason}}
        end

      {:pending, _request} = pending ->
        {:pending, pending}

      {:error, {:approval_denied, _reason}} = denied ->
        {:denied, denied}

      {:error, _reason} = error ->
        {:error, error}
    end
  end

  defp dispatch_timeout(call, opts, timeout) do
    case ToolCall.Timeout.run_tagged(
           fn -> invoke(call.module, call.tool, call.positional, call.validate_result?) end,
           timeout,
           opts
         ) do
      {:timeout, ms} ->
        {:timeout, {:error, {:timeout, ms}}}

      {:ok, {:raised, error}} ->
        {:raised, error}

      {:ok, result} ->
        {outcome_for(result), result}

      {:error, reason} ->
        {:error, {:error, reason}}
    end
  end

  defp outcome_for({:ok, _value}), do: :ok
  defp outcome_for({:error, _reason}), do: :error

  defp validate_static_timeout!(call, opts) do
    case Keyword.fetch(opts, :timeout) do
      {:ok, timeout} ->
        ToolCall.Timeout.validate!(timeout)

      :error ->
        if call.timeout_policy == nil, do: ToolCall.Timeout.validate!(call.timeout)
    end
  end

  defp effective_timeout(call, opts, context) do
    case Keyword.fetch(opts, :timeout) do
      {:ok, timeout} ->
        {:ok, timeout}

      :error ->
        case call.timeout_policy do
          nil -> {:ok, call.timeout}
          policy -> timeout_policy_result(policy, call, context)
        end
    end
  end

  defp timeout_policy_result(policy, call, context) do
    {:ok, ToolCall.Timeout.validate!(policy.timeout(call.tool, call.args, context))}
  rescue
    exception -> {:error, {:invalid_timeout, exception_message(exception)}}
  catch
    kind, value -> {:error, {:invalid_timeout, {kind, value}}}
  end

  defp resolve_tool(module, %Tool{} = tool, args, check_nested?, known, opts)
       when is_map(args) do
    known = known || Enum.map(tool.params || [], & &1.name)
    validate_result? = validate_result_opt!(opts)
    approval = approval_for(module, opts)
    audit = audit_for(module, opts)
    context = Keyword.get(opts, :context)
    {timeout, timeout_policy} = timeout_config(module, opts)

    with :ok <- reject_non_string_keys(args),
         :ok <- if(check_nested?, do: reject_nested_non_string_keys(tool, args), else: :ok),
         :ok <- reject_unknown_arguments(args, known),
         {:ok, values} <- coerce(tool, args),
         {:ok, positional} <- positional(tool, values) do
      {:ok,
       %ToolCall.Call{
         module: module,
         tool: tool,
         args: args,
         values: values,
         positional: positional,
         context: context,
         timeout: timeout,
         timeout_policy: timeout_policy,
         approval: approval,
         audit: audit,
         validate_result?: validate_result?
       }}
    end
  end

  defp audit_for(module, opts) do
    case Keyword.fetch(opts, :audit) do
      {:ok, audit} -> audit
      :error -> module_audit(module)
    end
  end

  defp module_audit(module) do
    case module_policy(module, :__audit_policy__) do
      nil ->
        nil

      policy ->
        ToolCall.Options.validate_policy!(policy, :record, 1, "audit")
        policy
    end
  end

  defp module_policy(module, function) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, 0) do
      apply(module, function, [])
    else
      nil
    end
  end

  defp audit_tool_name(name) when is_binary(name), do: name
  defp audit_tool_name(name) when is_atom(name), do: Atom.to_string(name)
  defp audit_tool_name(name), do: inspect(name)

  defp audit_failure(module, tool, args, opts, outcome, error, duration) do
    case audit_for(module, opts) do
      nil ->
        :ok

      audit ->
        context = Keyword.get(opts, :context)

        with {:ok, entry} <-
               audit_entry(module, tool, args, context, outcome,
                 duration_us: duration,
                 error: error
               ) do
          record_entry(audit, entry)
        end
    end
  end

  defp audit_entry(module, tool, args, context, outcome, opts) do
    {:ok, ToolCall.Audit.entry(module, tool, args, context, outcome, opts)}
  rescue
    _exception -> :error
  catch
    _kind, _value -> :error
  end

  defp with_audit(module, tool, args, opts, context, fun) do
    {duration, result} =
      :timer.tc(fn ->
        try do
          {:ok, fun.()}
        rescue
          exception -> {:error, :error, exception, __STACKTRACE__}
        catch
          kind, value -> {:error, kind, value, __STACKTRACE__}
        end
      end)

    case result do
      {:ok, value} ->
        value

      {:error, :error, exception, stacktrace} ->
        audit_exception(module, tool, args, opts, context, exception, duration)
        reraise exception, stacktrace

      {:error, kind, value, stacktrace} ->
        audit_exception(module, tool, args, opts, context, {kind, value}, duration)
        :erlang.raise(kind, value, stacktrace)
    end
  end

  defp audit_exception(module, tool, args, opts, context, exception, duration) do
    case audit_for(module, opts) do
      nil ->
        :ok

      audit ->
        with {:ok, entry} <-
               audit_entry(module, tool, args, context, :error,
                 duration_us: duration,
                 error: {:exception, exception_message(exception)}
               ) do
          record_entry(audit, entry)
        end
    end
  end

  defp exception_message(%{__exception__: true} = exception), do: Exception.message(exception)
  defp exception_message(other), do: inspect(other)

  defp record_audit(nil, _call, _outcome, _result, _duration, _context), do: :ok

  defp record_audit(policy, call, outcome, result, duration, context) do
    {error, request_id, timeout} = audit_fields(outcome, result)

    with {:ok, entry} <-
           audit_entry(call.module, call.tool.name, call.args, context, outcome,
             duration_us: duration,
             error: error,
             approval_request_id: request_id,
             timeout: timeout
           ) do
      record_entry(policy, entry)
    end
  end

  defp audit_fields(:ok, _result), do: {nil, nil, nil}

  defp audit_fields(:pending, {:pending, %ToolCall.Approval.Request{id: id}}),
    do: {nil, id, nil}

  defp audit_fields(:denied, {:error, {:approval_denied, reason}}), do: {reason, nil, nil}

  defp audit_fields(:timeout, {:error, {:timeout, ms}}), do: {{:timeout, ms}, nil, ms}

  defp audit_fields(:raised, {:error, {:raised, message}}), do: {message, nil, nil}

  defp audit_fields(:error, {:error, reason}), do: {reason, nil, nil}

  defp audit_fields(_outcome, _result), do: {nil, nil, nil}

  defp record_entry(policy, entry) when is_atom(policy) do
    ToolCall.Options.validate_policy!(policy, :record, 1, "audit")

    try do
      policy.record(entry)
    rescue
      _exception -> :ok
    catch
      _kind, _value -> :ok
    end
  end

  defp record_entry(other, _entry) do
    raise ArgumentError, "audit must be a module or nil, got: #{inspect(other)}"
  end

  defp approval_for(module, opts) do
    case Keyword.fetch(opts, :approval) do
      {:ok, approval} -> approval
      :error -> module_approval(module)
    end
  end

  defp module_approval(module) do
    case module_policy(module, :__approval_policy__) do
      nil ->
        nil

      policy ->
        ToolCall.Options.validate_policy!(policy, :check, 3, "approval")
        policy
    end
  end

  defp approve(_call, nil, _context), do: :ok
  defp approve(_call, :granted, _context), do: :ok
  defp approve(_call, :denied, _context), do: {:error, {:approval_denied, :denied}}

  defp approve(call, policy, context) when is_atom(policy) do
    ToolCall.Options.validate_policy!(policy, :check, 3, "approval")

    case policy.check(call.tool, call.args, context) do
      :approve ->
        :ok

      {:deny, reason} ->
        {:error, {:approval_denied, reason}}

      {:required, reason} ->
        {:pending, ToolCall.Approval.request(call.module, call.tool, call.args, reason, context)}

      other ->
        {:error, {:invalid_approval, other}}
    end
  end

  defp approve(_call, other, _context) do
    raise ArgumentError,
          "approval must be :granted, :denied, a module or nil, got: #{inspect(other)}"
  end

  defp timeout_config(module, opts) do
    case Keyword.fetch(opts, :timeout) do
      {:ok, timeout} ->
        {ToolCall.Timeout.validate!(timeout), nil}

      :error ->
        opts
        |> Keyword.fetch(:timeout_policy)
        |> timeout_policy_config(module)
    end
  end

  defp timeout_policy_config(:error, module), do: module_timeout_config(module)
  defp timeout_policy_config({:ok, nil}, module), do: module_timeout_config(module)

  defp timeout_policy_config({:ok, timeout}, _module)
       when is_integer(timeout) or timeout == :infinity do
    {ToolCall.Timeout.validate!(timeout), nil}
  end

  defp timeout_policy_config({:ok, policy}, _module)
       when is_atom(policy) and policy not in [true, false] do
    {:infinity, policy}
  end

  defp timeout_policy_config({:ok, other}, _module) do
    raise ArgumentError,
          "timeout_policy must be :infinity, a non-negative integer or a module, " <>
            "got: #{inspect(other)}"
  end

  defp module_timeout_config(module) do
    case module_policy(module, :__timeout_policy__) do
      nil ->
        {:infinity, nil}

      :infinity ->
        {:infinity, nil}

      timeout when is_integer(timeout) ->
        {ToolCall.Timeout.validate!(timeout), nil}

      policy when is_atom(policy) and policy not in [true, false] ->
        {:infinity, policy}

      other ->
        raise ArgumentError,
              "timeout must be :infinity or a non-negative integer, got: #{inspect(other)}"
    end
  end

  defp validate_options!(opts) do
    ToolCall.Options.validate!(opts, @option_keys)
  end

  @doc false
  @spec check_arguments(term(), [String.t()]) :: :ok | {:error, term()}
  def check_arguments(args, known) do
    {non_string, unknown} =
      Enum.reduce(Map.keys(args), {[], []}, fn key, {non_string, unknown} ->
        cond do
          not is_binary(key) -> {[key | non_string], unknown}
          key not in known -> {non_string, [key | unknown]}
          true -> {non_string, unknown}
        end
      end)

    cond do
      non_string != [] ->
        {:error, {:non_string_arguments, Enum.reverse(non_string)}}

      unknown != [] ->
        {:error, {:unknown_arguments, Enum.map(Enum.reverse(unknown), &to_string/1)}}

      true ->
        :ok
    end
  end

  @doc false
  @spec normalize(term()) :: {:ok, term()} | {:error, term()}
  def normalize({:ok, _value} = ok), do: ok
  def normalize({:error, _reason} = error), do: error
  def normalize(other), do: {:ok, other}

  @doc false
  @spec raised(Exception.t(), list()) :: {:error, {:raised, String.t()}}
  def raised(exception, stacktrace) do
    Logger.error(Exception.format(:error, exception, stacktrace))
    {:error, {:raised, Exception.message(exception)}}
  end

  @doc false
  @spec caught(:throw | :exit, term()) :: {:error, term()}
  def caught(:throw, value), do: {:error, {:thrown, value}}
  def caught(:exit, reason), do: {:error, {:exited, reason}}

  # Reporting a known name as "unknown" because it arrived as an atom is
  # misleading; JSON objects decode to strings, so say what is wrong.
  defp reject_non_string_keys(args) do
    case Enum.reject(Map.keys(args), &is_binary/1) do
      [] -> :ok
      keys -> {:error, {:non_string_arguments, keys}}
    end
  end

  defp reject_nested_non_string_keys(%Tool{} = tool, args) do
    defs = tool.defs || %{}

    keys =
      Enum.flat_map(tool.params, fn param ->
        case Map.fetch(args, param.name) do
          {:ok, value} -> nested_non_string_keys(param.type, value, defs)
          :error -> []
        end
      end)
      |> Enum.uniq()

    case keys do
      [] -> :ok
      keys -> {:error, {:non_string_arguments, keys}}
    end
  end

  defp nested_non_string_keys(%Type{kind: :object, source: :keyword} = type, value, defs)
       when is_map(value) do
    additional = type.additional

    Enum.flat_map(value, fn {_key, item} ->
      nested_non_string_keys(additional || %Type{kind: :any}, item, defs)
    end)
  end

  defp nested_non_string_keys(%Type{kind: :object} = type, value, defs) when is_map(value) do
    fields = type.fields || []
    bad_keys = value |> Map.keys() |> Enum.reject(&is_binary/1)

    nested =
      Enum.flat_map(value, fn {key, item} ->
        field = Enum.find(fields, &(&1.name == key or &1.key == key))
        nested_type = if field, do: field.type, else: type.additional

        if nested_type,
          do: nested_non_string_keys(nested_type, item, defs),
          else: []
      end)

    bad_keys ++ nested
  end

  defp nested_non_string_keys(%Type{kind: :array, items: items}, value, defs)
       when is_list(value) do
    Enum.flat_map(value, &nested_non_string_keys(items || %Type{kind: :any}, &1, defs))
  end

  defp nested_non_string_keys(%Type{kind: :tuple, items: items}, value, defs)
       when is_list(value) or is_tuple(value) do
    values = if is_tuple(value), do: Tuple.to_list(value), else: value
    items = items || []

    values
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} ->
      case Enum.at(items, index) do
        nil -> []
        type -> nested_non_string_keys(type, item, defs)
      end
    end)
  end

  defp nested_non_string_keys(%Type{kind: :ref, ref: ref}, value, defs) do
    case Map.fetch(defs, ref) do
      {:ok, type} -> nested_non_string_keys(type, value, defs)
      :error -> []
    end
  end

  defp nested_non_string_keys(%Type{kind: :union} = type, value, defs) do
    variants = type.variants || []

    if Enum.any?(variants, &(&1.kind in [:any, :unsupported])) do
      []
    else
      variants
      |> Enum.flat_map(&nested_non_string_keys(&1, value, defs))
      |> Enum.uniq()
    end
  end

  defp nested_non_string_keys(%Type{}, _value, _defs), do: []

  defp fetch(tools, name) do
    case Enum.find(tools, &(&1.name == name)) do
      nil -> {:error, {:unknown_tool, name, Enum.map(tools, & &1.name)}}
      tool -> {:ok, %{tool | params: tool.params || []}}
    end
  end

  defp reject_unknown_arguments(args, known) do
    case Enum.reject(Map.keys(args), &(&1 in known)) do
      [] -> :ok
      unknown -> {:error, {:unknown_arguments, Enum.map(unknown, &to_string/1)}}
    end
  end

  defp coerce(%Tool{} = tool, args) do
    Enum.reduce_while(tool.params, {:ok, %{}}, fn param, {:ok, acc} ->
      case coerce_param(param, args, tool.defs || %{}) do
        {:ok, :missing} -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, Map.put(acc, param.name, value)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp coerce_param(%Param{} = param, args, defs) do
    case Map.fetch(args, param.name) do
      {:ok, nil} when not param.required ->
        if Coerce.accepts_nil?(param.type, defs),
          do: coerce_value(param, nil, defs),
          else: {:ok, :missing}

      {:ok, raw} ->
        coerce_value(param, raw, defs)

      :error ->
        missing_param(param)
    end
  end

  defp coerce_value(%Param{} = param, raw, defs) do
    case Coerce.param(param, raw, defs) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, {:invalid_argument, reason}}
    end
  end

  defp missing_param(%Param{required: true} = param),
    do: {:error, {:missing_argument, param.name}}

  defp missing_param(%Param{}), do: {:ok, :missing}

  # Elixir fills defaults in declaration order: a reduced-arity call receives
  # every required argument plus a prefix of the optional arguments. A required
  # argument after an omitted optional one is fine; a later optional argument
  # after an omitted optional one is not, because apply/3 would shift it into
  # the wrong position.
  defp positional(%Tool{} = tool, values) do
    params = tool.params || []
    provided = Enum.filter(params, &Map.has_key?(values, &1.name))
    optional = Enum.filter(params, &(not &1.required))
    provided_optional = Enum.filter(optional, &Map.has_key?(values, &1.name))

    if optional_prefix?(provided_optional, optional) do
      {:ok, Enum.map(provided, &Map.fetch!(values, &1.name))}
    else
      {missing, dropped} = first_optional_gap(optional, values)
      {:error, {:argument_gap, missing.name, Enum.map(dropped, & &1.name)}}
    end
  end

  defp optional_prefix?(provided, optional), do: Enum.take(optional, length(provided)) == provided

  defp first_optional_gap(optional, values) do
    {_before, [missing | rest]} =
      Enum.split_while(optional, &Map.has_key?(values, &1.name))

    dropped = Enum.filter(rest, &Map.has_key?(values, &1.name))
    {missing, dropped}
  end

  defp invoke(module, %Tool{} = tool, args, validate_result?) do
    case apply_tool(module, tool, args) do
      {:ok, value} ->
        with :ok <- maybe_validate_result(tool, value, validate_result?), do: normalize(value)

      {:raised, error} ->
        {:raised, error}

      {:error, _reason} = error ->
        error
    end
  end

  defp apply_tool(module, %Tool{} = tool, args) do
    {:ok, apply(module, tool.fun, args)}
  rescue
    exception -> {:raised, raised(exception, __STACKTRACE__)}
  catch
    :throw, value -> caught(:throw, value)
    :exit, reason -> caught(:exit, reason)
  end

  defp validate_result_opt!(opts) do
    case Keyword.get(opts, :validate_result, false) do
      value when is_boolean(value) -> value
      other -> raise ArgumentError, "validate_result must be a boolean, got: #{inspect(other)}"
    end
  end

  defp maybe_validate_result(_tool, _value, false), do: :ok
  defp maybe_validate_result(%Tool{result: nil}, _value, _validate?), do: :ok

  defp maybe_validate_result(%Tool{result: result, defs: defs}, value, true) do
    case Validate.valid?(result, value, defs || %{}) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_result, reason}}
    end
  end
end
