defmodule ToolCall.Generated do
  @moduledoc false
  # Phase-one modules call these helpers from their generated `__tools__/0` and
  # `__schemas__/0`. The phase-two companion carries the typedoc-enriched
  # literals; its fingerprint makes a stale or partially written companion fall
  # back to the phase-one data instead of serving old tools.

  alias ToolCall.IR.Tool

  @spec companion(module()) :: module()
  def companion(module), do: Module.concat(module, "__ToolCall__")

  @spec fingerprint([Tool.t()], map()) :: non_neg_integer()
  def fingerprint(tools, schemas), do: :erlang.phash2({tools, schemas})

  @spec tools(module(), non_neg_integer(), [Tool.t()]) :: [Tool.t()]
  def tools(companion, fingerprint, fallback) do
    if current?(companion, :__tools__, fingerprint), do: companion.__tools__(), else: fallback
  end

  @spec schemas(module(), non_neg_integer(), map()) :: map()
  def schemas(companion, fingerprint, fallback) do
    if current?(companion, :__schemas__, fingerprint), do: companion.__schemas__(), else: fallback
  end

  defp current?(companion, function, fingerprint) do
    loaded? = Code.ensure_loaded?(companion)
    exported? = function_exported?(companion, function, 0)
    stamped? = function_exported?(companion, :__fingerprint__, 0)

    if loaded? and exported? and stamped? do
      companion.__fingerprint__() == fingerprint
    else
      false
    end
  end
end
