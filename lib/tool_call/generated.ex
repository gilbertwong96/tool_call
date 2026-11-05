defmodule ToolCall.Generated do
  @moduledoc false
  # Phase-one modules call these helpers from their generated `__tools__/0` and
  # `__schemas__/0`. The phase-two companion carries the typedoc-enriched
  # literals and the compile-generation token. The token is not a hash of the
  # enriched content: it changes on every phase-one compile, so a typedoc-only
  # change still invalidates a stale or partially written companion and falls
  # back to the phase-one data. The token combines wall-clock nanoseconds with
  # a VM-local counter, so it is unique across VM restarts (each `mix compile`
  # starts a fresh VM), not merely unique within one VM.

  alias ToolCall.IR.Tool

  @generation_shift 64

  @spec companion(module()) :: module()
  def companion(module), do: Module.concat(module, "__ToolCall__")

  @spec generation() :: pos_integer()
  def generation do
    timestamp = System.system_time(:nanosecond)
    unique = :erlang.unique_integer([:positive])
    Bitwise.bsl(timestamp, @generation_shift) + unique
  end

  @spec tools(module(), pos_integer(), [Tool.t()]) :: [Tool.t()]
  def tools(companion, generation, fallback) do
    if current?(companion, :__tools__, generation), do: companion.__tools__(), else: fallback
  end

  @spec schemas(module(), pos_integer(), map()) :: map()
  def schemas(companion, generation, fallback) do
    if current?(companion, :__schemas__, generation), do: companion.__schemas__(), else: fallback
  end

  defp current?(companion, function, generation) do
    loaded? = Code.ensure_loaded?(companion)
    exported? = function_exported?(companion, function, 0)
    stamped? = function_exported?(companion, :__generation__, 0)

    if loaded? and exported? and stamped? do
      companion.__generation__() == generation
    else
      false
    end
  end
end
