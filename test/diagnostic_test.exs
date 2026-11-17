defmodule ToolCall.DiagnosticTest do
  use ExUnit.Case, async: true

  alias ToolCall.Diagnostic

  test "builds warnings and errors with their messages" do
    assert %Diagnostic{severity: :warning, message: "careful"} = Diagnostic.warning("careful")
    assert %Diagnostic{severity: :error, message: "broken"} = Diagnostic.error("broken")
    assert Diagnostic.message(Diagnostic.warning("careful")) == "careful"
  end
end
