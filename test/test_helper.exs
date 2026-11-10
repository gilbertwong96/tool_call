ExUnit.start()

defmodule ToolCall.TestModule do
  @moduledoc false

  @doc "Compiles `source`, replacing `FIXTURE` with a unique module name."
  def compile!(source) do
    # A typedoc fixture may compile its companion first, so select the fixture
    # module by name instead of relying on compilation order.
    {module, _diagnostics} = compile_source(source)
    module
  end

  @doc "Compiles `source` and returns `{module, warning_messages}`."
  def compile_with_warnings!(source) do
    {module, diagnostics} = compile_with_diagnostics!(source)
    {module, Enum.map_join(diagnostics, "\n", & &1.message)}
  end

  @doc "Compiles `source` and returns `{module, diagnostics}` with locations."
  def compile_with_diagnostics!(source) do
    compile_source(source)
  end

  @doc "Returns the emitted OpenAI schema for one parameter of one tool."
  def param_schema(module, tool, param) do
    module
    |> ToolCall.emit(:openai)
    |> Enum.find(&(&1["function"]["name"] == tool))
    |> get_in(["function", "parameters", "properties", param])
  end

  # `Code.with_diagnostics/1` collects compiler diagnostics (including
  # `IO.warn/2`) as data instead of writing to the shared stderr device, which
  # keeps these tests safe under `async: true`.
  defp compile_source(source) do
    source =
      if String.contains?(source, "FIXTURE") do
        String.replace(source, "FIXTURE", "Fixture#{System.unique_integer([:positive])}")
      else
        source
      end

    {compiled, diagnostics} =
      Code.with_diagnostics(fn -> Code.compile_string(source) end)

    {module, _binary} =
      Enum.find(compiled, fn {compiled_module, _binary} ->
        not String.ends_with?(Atom.to_string(compiled_module), ".__ToolCall__") and
          function_exported?(compiled_module, :__tools__, 0)
      end) ||
        Enum.find(compiled, fn {compiled_module, _binary} ->
          not String.ends_with?(Atom.to_string(compiled_module), ".__ToolCall__")
        end)

    {module, diagnostics}
  end
end
