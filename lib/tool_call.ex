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

  Everything is generated at compile time from module attributes. Nothing is
  read back from the compiled beam at runtime, because release builds strip the
  `Docs` and `Dbgi` chunks. See `docs/pitfalls.md`.

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
      Module.register_attribute(__MODULE__, :tool_param, accumulate: true)
      @on_definition ToolCall
      @before_compile ToolCall
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
    tools = ToolCall.Builder.build(module, defs, specs, overrides, env, providers)
    schemas = ToolCall.Emit.precompile(tools)
    embedded = Enum.map(tools, &drop_provenance/1)

    quote do
      @doc false
      def __tools__, do: unquote(Macro.escape(embedded))

      @doc false
      def __schemas__, do: unquote(Macro.escape(schemas))

      @doc false
      def __tool__(name), do: Enum.find(__tools__(), &(&1.name == to_string(name)))

      @doc false
      def __run__(name, args), do: ToolCall.Runner.run(__MODULE__, __tools__(), name, args)
    end
  end

  @doc """
  Returns the tools derived from a module.

  The embedded IR keeps `Type.source`, which calendar and charlist handling
  need at runtime, and drops the spec and parameter ASTs, which are
  compile-time provenance only.
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
  Emits schemas for `target` (`:openai` or `:anthropic`).

  For a module the supported variants are rendered at **compile time** and
  embedded as a literal, so this is a map lookup and `strict` may be a runtime
  boolean. A module returns a list with one schema per tool; a single
  `ToolCall.IR.Tool` returns one schema map and a list of them a list, rendered
  on demand, which is what dynamically built tools need.

  ## Options

    * `:strict` - OpenAI strict mode. The tool object carries
      `"strict": true`, every property becomes required, optional values
      become nullable and every object is closed, which is the only shape the
      API accepts when `strict: true` is set. Ignored for `:anthropic`.
  """
  @spec emit(module() | [Tool.t()] | Tool.t(), :openai | :anthropic, keyword()) ::
          map() | [map()]
  def emit(module_or_tools, target, opts \\ [])

  def emit(module, target, opts) when is_atom(module) do
    ensure_tool_module!(module)
    ToolCall.Emit.lookup(module.__schemas__(), target, opts)
  end

  def emit(%Tool{} = tool, target, opts), do: ToolCall.Emit.emit(tool, target, opts)
  def emit(tools, target, opts) when is_list(tools), do: ToolCall.Emit.emit(tools, target, opts)

  @doc "Runs a tool by name. `args` uses string keys, as decoded from JSON."
  @spec run(module(), atom() | String.t(), term()) :: {:ok, term()} | {:error, term()}
  def run(module, name, args) do
    ensure_tool_module!(module)
    module.__run__(name, args)
  end

  # `Type.source` is runtime data (calendar and charlist handling);
  # the spec and parameter ASTs are compile-time provenance only.
  defp drop_provenance(%Tool{} = tool) do
    %{tool | source: nil, params: Enum.map(tool.params, &%{&1 | source: nil})}
  end

  defp ensure_tool_module!(module) do
    if not (is_atom(module) and Code.ensure_loaded?(module) and
              function_exported?(module, :__tools__, 0)) do
      raise ArgumentError, "#{inspect(module)} does not use ToolCall"
    end
  end
end
