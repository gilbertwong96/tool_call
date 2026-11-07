defmodule Mix.Tasks.ToolCall.Clean do
  use Mix.Task

  @shortdoc "Removes orphaned typedoc companions"

  @moduledoc """
  Removes orphaned typedoc companion beams.

  A companion is normally cleaned when the source module is recompiled or when
  another ToolCall module is compiled. If the source file was deleted, or the
  module was removed from an existing file, and no ToolCall module has been
  compiled since, run this task before assembling a release. A live source in
  either the `.source` sidecar or the beam's `compile_info.source` keeps the
  companion; legacy companions without a sidecar use `compile_info.source` when
  available.

      mix tool_call.clean
  """

  @impl Mix.Task
  def run(_argv) do
    case ToolCall.Generated.clean() do
      0 -> Mix.shell().info("No stale ToolCall companions found")
      count -> Mix.shell().info("Removed #{count} stale ToolCall companion(s)")
    end
  end
end
