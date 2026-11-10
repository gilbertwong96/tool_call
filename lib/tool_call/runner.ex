defmodule ToolCall.Runner do
  @moduledoc """
  Validates and dispatches a decoded argument map to the tool function.

  Validation is generated from the same IR that produced the schema, so the
  parameter set, its names and its types cannot drift between the two.
  """

  require Logger

  alias ToolCall.{Coerce, Typespec, Validate}
  alias ToolCall.IR.{Param, Tool, Type}

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
          {:ok, term()} | {:error, term()}
  def run(module, tools, name, args, opts \\ [])

  def run(module, tools, name, args, opts) when is_map(args) do
    tools = Enum.map(tools, &Typespec.validate_tool!/1)
    run_prepared(module, tools, name, args, opts)
  end

  def run(_module, _tools, _name, args, _opts), do: {:error, {:invalid_arguments, args}}

  @doc """
  Internal fast path for already prepared tools.

  This skips runtime IR validation. Callers must pass tools prepared by
  `ToolCall.Typespec.validate_tool!/1`; use `run/4` for arbitrary runtime tools.
  """
  @spec run_prepared(module(), [Tool.t()], atom() | String.t(), term(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def run_prepared(module, tools, name, args, opts \\ [])

  def run_prepared(module, tools, name, args, opts) when is_map(args) do
    name = to_string(name)

    case fetch(tools, name) do
      {:ok, tool} ->
        run_prepared_tool(module, tool, args, true, nil, opts)

      error ->
        audit_failure(module, name, args, opts, :unknown_tool, nil, 0)
        error
    end
  end

  def run_prepared(_module, _tools, _name, args, _opts),
    do: {:error, {:invalid_arguments, args}}

  @doc false
  @spec run_prepared_tool(module(), Tool.t(), term()) :: {:ok, term()} | {:error, term()}
  def run_prepared_tool(module, %Tool{} = tool, args) do
    run_prepared_tool(module, tool, args, true, nil, [])
  end

  @doc false
  @spec run_prepared_tool(module(), Tool.t(), term(), boolean(), [String.t()] | nil) ::
          {:ok, term()} | {:error, term()}
  def run_prepared_tool(module, %Tool{} = tool, args, check_nested?, known) do
    run_prepared_tool(module, tool, args, check_nested?, known, [])
  end

  @doc false
  @spec run_prepared_tool(module(), Tool.t(), term(), boolean(), [String.t()] | nil, keyword()) ::
          {:ok, term()} | {:error, term()}
  def run_prepared_tool(module, %Tool{} = tool, args, check_nested?, known, opts)
      when is_map(args) do
    {duration, resolved} =
      :timer.tc(fn -> resolve_tool(module, tool, args, check_nested?, known, opts) end)

    case resolved do
      {:ok, call} ->
        execute(call, opts)

      {:error, reason} = error ->
        audit_failure(module, tool.name, args, opts, :invalid_arguments, reason, duration)
        error
    end
  end

  def run_prepared_tool(_module, %Tool{}, args, _check_nested?, _known, _opts),
    do: {:error, {:invalid_arguments, args}}

  @doc """
  Resolves a tool call without invoking it.

  Runs the key checks, coercion and positional construction and answers a
  `ToolCall.Call` that `execute/2` can run later. No side effect is performed.
  A hand-built tool is validated first; invalid IR raises `ArgumentError`.
  """
  @spec resolve(module(), Tool.t(), map(), keyword()) ::
          {:ok, ToolCall.Call.t()} | {:error, term()}
  def resolve(module, tool, args, opts \\ [])

  def resolve(module, %Tool{} = tool, args, opts) when is_map(args) do
    resolve_tool(module, Typespec.validate_tool!(tool), args, true, nil, opts)
  end

  def resolve(_module, %Tool{}, args, _opts), do: {:error, {:invalid_arguments, args}}

  @doc """
  Executes a call produced by `resolve/4`.

  The call's timeout applies unless `:timeout` is given. `:task_supervisor` is
  passed to `ToolCall.Timeout.run/3`. The stored approval policy is checked
  unless `:approval` overrides it; a `{:required, reason}` answer returns
  `{:pending, %ToolCall.Approval.Request{}}` without invoking.
  """
  @spec execute(ToolCall.Call.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def execute(%ToolCall.Call{} = call, opts \\ []) do
    audit = Keyword.get(opts, :audit, call.audit)
    {duration, result} = :timer.tc(fn -> do_execute(call, opts) end)
    record_audit(audit, call, result, duration, opts)
    result
  end

  defp do_execute(call, opts) do
    approval = Keyword.get(opts, :approval, call.approval)

    with :ok <- approve(call, approval, opts) do
      timeout = Keyword.get(opts, :timeout, call.timeout)
      ToolCall.Timeout.validate!(timeout)

      ToolCall.Timeout.run(
        fn -> invoke(call.module, call.tool, call.positional, call.validate_result?) end,
        timeout,
        opts
      )
    end
  end

  defp resolve_tool(module, %Tool{} = tool, args, check_nested?, known, opts)
       when is_map(args) do
    known = known || Enum.map(tool.params || [], & &1.name)
    validate_result? = validate_result_opt!(opts)
    timeout = timeout_for(tool, args, opts)
    approval = approval_for(module, opts)
    audit = audit_for(module, opts)

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
         timeout: timeout,
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
    if function_exported?(module, :__audit_policy__, 0) do
      module.__audit_policy__()
    else
      nil
    end
  end

  defp audit_failure(module, tool, args, opts, outcome, error, duration) do
    audit = audit_for(module, opts)
    context = Keyword.get(opts, :context)

    entry =
      ToolCall.Audit.entry(module, tool, args, context, outcome,
        duration_us: duration,
        error: error
      )

    record_entry(audit, entry)
  end

  defp record_audit(nil, _call, _result, _duration, _opts), do: :ok

  defp record_audit(policy, call, result, duration, opts) do
    {outcome, error, request_id, timeout} = audit_result(result)
    context = Keyword.get(opts, :context)

    entry =
      ToolCall.Audit.entry(call.module, call.tool.name, call.args, context, outcome,
        duration_us: duration,
        error: error,
        approval_request_id: request_id,
        timeout: timeout
      )

    record_entry(policy, entry)
  end

  defp audit_result({:ok, _value}), do: {:ok, nil, nil, nil}

  defp audit_result({:pending, %ToolCall.Approval.Request{id: id}}),
    do: {:pending, nil, id, nil}

  defp audit_result({:error, {:approval_denied, reason}}), do: {:denied, reason, nil, nil}

  defp audit_result({:error, {:timeout, ms}}), do: {:timeout, {:timeout, ms}, nil, ms}

  defp audit_result({:error, {:raised, message}}), do: {:raised, message, nil, nil}

  defp audit_result({:error, reason}), do: {:error, reason, nil, nil}

  defp record_entry(nil, _entry), do: :ok

  defp record_entry(policy, entry) when is_atom(policy) do
    unless Code.ensure_loaded?(policy) and function_exported?(policy, :record, 1) do
      raise ArgumentError, "audit policy #{inspect(policy)} does not export record/1"
    end

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
    if function_exported?(module, :__approval_policy__, 0) do
      module.__approval_policy__()
    else
      nil
    end
  end

  defp approve(_call, nil, _opts), do: :ok
  defp approve(_call, :granted, _opts), do: :ok
  defp approve(_call, :denied, _opts), do: {:error, {:approval_denied, :denied}}

  defp approve(call, policy, opts) when is_atom(policy) do
    if Code.ensure_loaded?(policy) and function_exported?(policy, :check, 3) do
      context = Keyword.get(opts, :context)

      case policy.check(call.tool, call.args, context) do
        :approve ->
          :ok

        {:deny, reason} ->
          {:error, {:approval_denied, reason}}

        {:required, reason} ->
          {:pending,
           ToolCall.Approval.request(call.module, call.tool, call.args, reason, context)}

        other ->
          {:error, {:invalid_approval, other}}
      end
    else
      raise ArgumentError, "approval policy #{inspect(policy)} does not export check/3"
    end
  end

  defp approve(_call, other, _opts) do
    raise ArgumentError,
          "approval must be :granted, :denied, a module or nil, got: #{inspect(other)}"
  end

  defp timeout_for(tool, args, opts) do
    timeout =
      case Keyword.fetch(opts, :timeout) do
        {:ok, timeout} ->
          timeout

        :error ->
          case Keyword.get(opts, :timeout_policy) do
            nil ->
              :infinity

            timeout when is_integer(timeout) or timeout == :infinity ->
              timeout

            policy when is_atom(policy) ->
              policy.timeout(tool, args, Keyword.get(opts, :context))
          end
      end

    ToolCall.Timeout.validate!(timeout)
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

      {:error, _reason} = error ->
        error
    end
  end

  defp apply_tool(module, %Tool{} = tool, args) do
    {:ok, apply(module, tool.fun, args)}
  rescue
    exception -> raised(exception, __STACKTRACE__)
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
