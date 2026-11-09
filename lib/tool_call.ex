defmodule ToolCall do
  @moduledoc """
  Derive LLM tool-call schemas from `@spec` and `@doc`.

      defmodule MyApp.Tools.Weather do
        use ToolCall

        @doc \"\"\"
        Get the forecast for a city.

        ## Parameters
          * `city` - city name
          * `days` - how many days ahead
        \"\"\"
        @spec get_weather(city :: String.t(), days :: pos_integer() | nil) ::
                {:ok, %{temp: float()}} | {:error, String.t()}
        def get_weather(city, days \\\\ 3)
      end

      ToolCall.emit(MyApp.Tools.Weather, :openai)
      ToolCall.run(MyApp.Tools.Weather, :get_weather, %{"city" => "Shanghai"})

  Everything is generated at compile time from module attributes. No runtime
  path reads the `Docs` or `Dbgi` chunks, because release builds strip them.
  Visible local `@typedoc` text is recovered in a second compile phase
  (`@after_compile`) and embedded in a generated companion module; runtime code
  never calls `Code.fetch_docs/1`. The companion is ordinary compiled code,
  loaded on first use like any other module.

  ## Supported typespec subset

  See `docs/design.md`. `@type`, `@typep` and `@opaque` declarations in the same
  module are resolved before mapping, including parameterised ones. Unknown
  types degrade to `{}` (any value) rather than failing compilation unless a
  `ToolCall.TypeProvider` registered with `use ToolCall, types: [...]` resolves
  them; types that JSON cannot express at all (functions, pids, refs) are
  flagged with a compile-time warning.
  """

  if not (Code.ensure_loaded?(:json) and function_exported?(:json, :format, 1)) do
    raise "ToolCall requires Erlang/OTP 27.1+ (json:format/1 is unavailable)"
  end

  alias ToolCall.{Emit, Generated, Typedoc}
  alias ToolCall.IR.Tool

  @doc false
  defmacro __using__(opts) do
    {types, rest} = Keyword.pop(opts, :types, [])

    if rest != [] do
      raise ArgumentError, "use ToolCall accepts only :types, got: #{inspect(rest)}"
    end

    providers = ToolCall.Typespec.builtin_providers() ++ expand_providers(types, __CALLER__)

    quote do
      @tool_call_type_providers unquote(providers)
      Module.register_attribute(__MODULE__, :tool_call_defs, accumulate: true)
      Module.register_attribute(__MODULE__, :tool_call_struct_fields, [])
      Module.register_attribute(__MODULE__, :tool_param, accumulate: true)
      @on_definition ToolCall
      @before_compile ToolCall
      @after_compile ToolCall
      unquote_splicing(for provider <- providers, do: quote(do: require(unquote(provider))))
    end
  end

  defp expand_providers(providers, env) when is_list(providers) do
    Enum.map(providers, fn provider ->
      case Macro.expand(provider, env) do
        module when is_atom(module) and module not in [nil, true, false] ->
          module

        _other ->
          raise ArgumentError, "expected a module in :types, got: #{inspect(provider)}"
      end
    end)
  end

  defp expand_providers(other, _env) do
    raise ArgumentError, ":types must be a list of modules, got: #{inspect(other)}"
  end

  @doc false
  # `defstruct` generates `__struct__/0` with the full field map as its body.
  # The module is not compiled yet when its tools resolve, so capture that map:
  # it is the only way to know every field of a struct defined here.
  def __on_definition__(env, :def, :__struct__, [], _guards, [{:do, {:%{}, _, pairs}}]) do
    fields = Enum.reject(pairs, fn {key, _default} -> key in [:__struct__, :__exception__] end)
    Module.put_attribute(env.module, :tool_call_struct_fields, fields)
    :ok
  end

  # `__struct__/0` and `__struct__/1` are not tools; they would otherwise warn
  # about a missing @spec.
  def __on_definition__(_env, :def, :__struct__, _args, _guards, _body), do: :ok

  def __on_definition__(env, :def, name, args, _guards, _body) do
    doc = Module.get_attribute(env.module, :doc)
    Module.put_attribute(env.module, :tool_call_defs, {name, args, doc, env.file, env.line})
  end

  def __on_definition__(_env, _kind, _name, _args, _guards, _body), do: :ok

  @doc false
  defmacro __before_compile__(env) do
    module = env.module
    defs = module |> Module.get_attribute(:tool_call_defs) |> List.wrap()
    specs = Module.get_attribute(module, :spec) |> List.wrap()
    overrides = module |> Module.get_attribute(:tool_param) |> List.wrap()

    providers = Module.get_attribute(module, :tool_call_type_providers) || []

    %{tools: tools, typedoc_keys: typedoc_keys} =
      ToolCall.Builder.build(module, defs, specs, overrides, env, providers)

    # Phase two only fills parameters that have no description yet. A compile
    # with `docs: false` writes no Docs chunk, so there is nothing to recover
    # and the effective key map is empty.
    typedoc_keys =
      if Code.compiler_options()[:docs] == false do
        %{}
      else
        typedoc_keys
      end

    generation = Generated.generation()
    companion = Generated.companion(module)
    schemas = Emit.precompile(tools)
    embedded = Enum.map(tools, &drop_provenance/1)

    # Phase two runs after the module closes, when the Docs chunk is available.
    Module.put_attribute(module, :tool_call_after_compile, %{
      tools: embedded,
      typedoc_keys: typedoc_keys,
      generation: generation
    })

    # A module with an empty effective key map can never gain a companion, so
    # its accessors return the phase-one literals directly. Only modules that
    # may receive a companion pay for the generation guard at runtime.
    tools_body =
      if map_size(typedoc_keys) == 0 do
        Macro.escape(embedded)
      else
        quote do
          ToolCall.Generated.tools(
            unquote(companion),
            unquote(generation),
            unquote(Macro.escape(embedded))
          )
        end
      end

    schemas_body =
      if map_size(typedoc_keys) == 0 do
        Macro.escape(schemas)
      else
        quote do
          ToolCall.Generated.schemas(
            unquote(companion),
            unquote(generation),
            unquote(Macro.escape(schemas))
          )
        end
      end

    runner_clauses = runner_clauses(tools, embedded)

    quote do
      @doc false
      def __tools__, do: unquote(tools_body)

      @doc false
      def __schemas__, do: unquote(schemas_body)

      @doc false
      def __tool__(name), do: Enum.find(__tools__(), &(&1.name == to_string(name)))

      unquote_splicing(runner_clauses)

      @doc false
      def __run__(name, args),
        do: ToolCall.Runner.run_prepared(__MODULE__, __tools__(), name, args)
    end
  end

  defp runner_clauses(tools, embedded) do
    indirect = for tool <- tools, no_return_spec?(tool.source), do: tool.name
    ToolCall.Codegen.runner_clauses(embedded, indirect)
  end

  defp no_return_spec?({:"::", _, [_args, {:no_return, _, []}]}), do: true
  defp no_return_spec?(_spec), do: false

  # Phase two: recover visible typedocs from the just-compiled bytecode and
  # publish a companion only when at least one description changed. The
  # callback is deliberately total: a failed enhancement warns and leaves the
  # phase-one literals in place rather than failing the user's compile.
  @doc false
  @spec __after_compile__(Macro.Env.t(), binary()) :: :ok
  def __after_compile__(env, bytecode) do
    module = env.module

    case Module.get_attribute(module, :tool_call_after_compile) do
      %{tools: tools, typedoc_keys: typedoc_keys, generation: generation} ->
        if map_size(typedoc_keys) == 0 do
          Generated.remove(env, Generated.companion(module))
        else
          enrich(env, bytecode, tools, typedoc_keys, generation)
        end

      _other ->
        :ok
    end

    Generated.prune()
    :ok
  catch
    # Companion management asks Mix for the compile path. A module compiled
    # outside a Mix project (a plain `elixirc` or an `elixir` script) has no
    # `Mix.ProjectStack`, and the call exits rather than raising; keep the
    # compile total and serve the phase-one literals instead.
    :exit, _reason -> :ok
  end

  defp enrich(env, bytecode, tools, typedoc_keys, generation) do
    companion = Generated.companion(env.module)

    case Typedoc.from_bytecode_result(bytecode) do
      {:ok, typedocs} ->
        enriched = Typedoc.apply(tools, typedoc_keys, typedocs)

        if enriched == tools do
          Generated.remove(env, companion)
        else
          Generated.create(
            env,
            companion,
            enriched,
            Emit.precompile(enriched),
            generation
          )
        end

      {:error, reason} ->
        Generated.remove(env, companion)
        warn_docs_failure(env, reason)
    end

    :ok
  rescue
    exception ->
      IO.warn(
        "#{inspect(env.module)}: typedoc enrichment failed " <>
          "(#{Exception.message(exception)}); using phase-one descriptions",
        file: env.file,
        line: env.line
      )

      :ok
  end

  defp warn_docs_failure(env, :missing_docs_chunk) do
    # `docs: false` is a deliberate compile option, not a broken beam; the
    # missing chunk is expected and the typedoc fallback is simply skipped.
    if Code.compiler_options()[:docs] != false do
      IO.warn(
        "#{inspect(env.module)}: the Docs chunk is missing, so @typedoc descriptions " <>
          "were skipped; using phase-one descriptions",
        file: env.file,
        line: env.line
      )
    end
  end

  defp warn_docs_failure(env, :corrupt_docs_chunk) do
    IO.warn(
      "#{inspect(env.module)}: the Docs chunk could not be decoded or has an " <>
        "unexpected structure, so @typedoc descriptions were skipped; using " <>
        "phase-one descriptions",
      file: env.file,
      line: env.line
    )
  end

  defp warn_docs_failure(env, :unreadable_beam) do
    IO.warn(
      "#{inspect(env.module)}: the compiled beam could not be read, so @typedoc " <>
        "descriptions were skipped; using phase-one descriptions",
      file: env.file,
      line: env.line
    )
  end

  @doc """
  Returns the tools derived from a module.

  The embedded IR keeps `Type.source`, which charlist handling needs at
  runtime, and drops the spec and parameter ASTs, which are compile-time
  provenance only.
  """
  @spec tools(module()) :: [Tool.t()]
  def tools(module) do
    ensure_tool_module!(module)
    module.__tools__()
  end

  @doc """
  Returns a provider-neutral description of every tool in `module`.

  Each entry has `:module`, `:name`, `:description` and `:parameters`, where
  `:parameters` is the JSON Schema object for the arguments with no provider
  envelope around it. Use this when your client owns the request format; use
  `emit/3` when you want the OpenAI or Anthropic envelope.

  ## Options

    * `:strict` - render the strict JSON Schema subset (see `emit/3`).
  """
  @spec describe(module(), keyword()) :: [
          %{module: module(), name: String.t(), description: String.t(), parameters: map()}
        ]
  def describe(module, opts \\ []) do
    for tool <- tools(module) do
      %{
        module: module,
        name: tool.name,
        description: tool.description || tool.name,
        parameters: ToolCall.Emit.Schema.params(tool, opts)
      }
    end
  end

  @doc "Returns the tool names derived from a module, in declaration order."
  @spec tool_names(module()) :: [String.t()]
  def tool_names(module), do: Enum.map(tools(module), & &1.name)

  @doc """
  Emits schemas for `target` (`:openai`, `:anthropic` or `:mcp`).

  For a module the OpenAI and Anthropic variants are rendered at **compile time**
  and embedded as a literal, so this is a direct or guarded map lookup and
  `strict` may be a runtime boolean. MCP is rendered on demand, because its
  `inputSchema` is the parameters object the other targets already embed. A
  module returns a list with one schema per tool; a single `ToolCall.IR.Tool`
  returns one schema map and a list of them a list, rendered on demand, which is
  what dynamically built tools need. Runtime IR is validated before rendering;
  invalid types raise `ArgumentError`.

  ## Options

    * `:strict` - OpenAI strict mode. The tool object carries
      `"strict": true`, every property becomes required, optional values
      become nullable and every object is closed, which is the only shape the
      API accepts when `strict: true` is set. For `:mcp` it renders the same
      closed subset without a flag (MCP has none). Ignored for `:anthropic`.
  """
  @spec emit(module() | [Tool.t()] | Tool.t(), :openai | :anthropic | :mcp, keyword()) ::
          map() | [map()]
  def emit(module_or_tools, target, opts \\ [])

  # MCP is not precompiled: its schema is the same parameters object the other
  # targets embed, so rendering it on demand keeps `__schemas__/0` unchanged.
  def emit(module, :mcp, opts) when is_atom(module) do
    ensure_tool_module!(module)
    Enum.map(module.__tools__(), &ToolCall.Emit.MCP.emit(&1, opts))
  end

  def emit(module, target, opts) when is_atom(module) do
    ensure_tool_module!(module, :__schemas__)
    ToolCall.Emit.lookup(module.__schemas__(), target, opts)
  end

  def emit(%Tool{} = tool, target, opts), do: ToolCall.Emit.emit(tool, target, opts)
  def emit(tools, target, opts) when is_list(tools), do: ToolCall.Emit.emit(tools, target, opts)

  @doc "Runs a tool by name. `args` uses string keys, as decoded from JSON."
  @spec run(module(), atom() | String.t(), term()) :: {:ok, term()} | {:error, term()}
  def run(module, name, args) do
    ensure_tool_module!(module, :__run__)
    module.__run__(name, args)
  end

  # `Type.source` is runtime data for charlist handling; the spec and parameter
  # ASTs are compile-time provenance only.
  defp drop_provenance(%Tool{} = tool) do
    %{tool | source: nil, params: Enum.map(tool.params, &%{&1 | source: nil})}
  end

  defp ensure_tool_module!(module, function \\ :__tools__) do
    loaded? = is_atom(module) and loaded_module?(module)

    if not (loaded? and function_exported?(module, function, function_arity(function))) do
      raise ArgumentError, "#{inspect(module)} does not use ToolCall"
    end
  end

  defp loaded_module?(module) do
    :code.is_loaded(module) != false or Code.ensure_loaded?(module)
  end

  defp function_arity(:__schemas__), do: 0
  defp function_arity(:__run__), do: 2
  defp function_arity(:__tools__), do: 0
end
