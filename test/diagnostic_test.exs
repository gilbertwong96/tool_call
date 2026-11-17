defmodule ToolCall.DiagnosticTest do
  use ExUnit.Case, async: true

  alias ToolCall.Diagnostic

  test "builds warnings and errors with their messages" do
    assert %Diagnostic{severity: :warning, message: "careful"} = Diagnostic.warning("careful")
    assert %Diagnostic{severity: :error, message: "broken"} = Diagnostic.error("broken")
    assert Diagnostic.message(Diagnostic.warning("careful")) == "careful"
  end

  test "carries an optional declaration position" do
    assert Diagnostic.position(Diagnostic.warning("no position")) == nil

    diagnostic = Diagnostic.error("located", line: 7, column: 3)
    assert Diagnostic.position(diagnostic) == {7, 3}
  end

  test "ignores a malformed position instead of failing the compile" do
    assert Diagnostic.position(Diagnostic.warning("bad", line: 0, column: "x")) == nil
    assert Diagnostic.position(Diagnostic.warning("bad", line: nil)) == nil
  end
end
