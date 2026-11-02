# The export task formats with json:format/1, which arrived in OTP 27.1.
export? = Code.ensure_loaded?(:json) and function_exported?(:json, :format, 1)

ExUnit.start(exclude: if(export?, do: [], else: [:export]))

defmodule ToolCall.TestModule do
  @moduledoc false

  @doc "Compiles `source`, replacing `FIXTURE` with a unique module name."
  def compile!(source) do
    {[{module, _binary}], _diagnostics} = compile_source(source)
    module
  end

  @doc "Compiles `source` and returns `{module, warning_messages}`."
  def compile_with_warnings!(source) do
    {module, diagnostics} = compile_with_diagnostics!(source)
    {module, Enum.map_join(diagnostics, "\n", & &1.message)}
  end

  @doc "Compiles `source` and returns `{module, diagnostics}` with locations."
  def compile_with_diagnostics!(source) do
    {[{module, _binary}], diagnostics} = compile_source(source)
    {module, diagnostics}
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
    name = "Fixture#{System.unique_integer([:positive])}"

    Code.with_diagnostics(fn ->
      Code.compile_string(String.replace(source, "FIXTURE", name))
    end)
  end
end
