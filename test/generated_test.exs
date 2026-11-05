defmodule ToolCall.GeneratedTest.MatchingFixture do
  @moduledoc false
  # Phase-one module stand-in; its enriched companion is derived by
  # ToolCall.Generated.companion/1.
end

# `MatchingFixture.__ToolCall__` is not a valid alias (segments start with an
# uppercase letter), so the companion is defined with its full atom name.
defmodule :"Elixir.ToolCall.GeneratedTest.MatchingFixture.__ToolCall__" do
  @moduledoc false

  @generation 73_001

  @tools [
    %ToolCall.IR.Tool{
      name: "companion",
      description: "Enriched by phase two",
      module: ToolCall.GeneratedTest.MatchingFixture,
      fun: :companion
    }
  ]

  @schemas %{{:openai, false} => [%{"type" => "function", "name" => "companion"}]}

  def __tools__, do: @tools
  def __schemas__, do: @schemas
  def __generation__, do: @generation
end

defmodule ToolCall.GeneratedTest.UnstampedCompanion do
  @moduledoc false

  @tools [%ToolCall.IR.Tool{name: "unstamped"}]

  def __tools__, do: @tools
  def __schemas__, do: %{}
end

defmodule ToolCall.GeneratedTest.ToolsOnlyCompanion do
  @moduledoc false

  @tools [%ToolCall.IR.Tool{name: "tools_only"}]

  def __tools__, do: @tools
  def __generation__, do: 7
end

defmodule ToolCall.GeneratedTest.SchemasOnlyCompanion do
  @moduledoc false

  @schemas %{{:openai, false} => [%{"type" => "function", "name" => "schemas_only"}]}

  def __schemas__, do: @schemas
  def __generation__, do: 11
end

defmodule ToolCall.GeneratedTest do
  use ExUnit.Case, async: true

  alias ToolCall.Generated
  alias ToolCall.IR.Tool

  @generation 73_001

  @fallback_tools [
    %Tool{
      name: "fallback",
      description: "Phase one",
      module: ToolCall.GeneratedTest.MatchingFixture,
      fun: :fallback
    }
  ]

  @fallback_schemas %{{:openai, false} => [%{"type" => "function", "name" => "fallback"}]}

  test "companion/1 derives the reserved companion module name" do
    assert Generated.companion(ToolCall.GeneratedTest.MatchingFixture) ==
             :"Elixir.ToolCall.GeneratedTest.MatchingFixture.__ToolCall__"
  end

  test "generation/0 returns unique positive integers" do
    first = Generated.generation()
    second = Generated.generation()

    assert is_integer(first)
    assert first > 0
    assert second > 0
    refute first == second
  end

  test "tools/3 delegates the enriched tools when the generation token matches" do
    companion = Generated.companion(ToolCall.GeneratedTest.MatchingFixture)
    tools = companion.__tools__()

    assert companion.__generation__() == @generation
    refute tools == @fallback_tools
    assert Generated.tools(companion, @generation, @fallback_tools) == tools
  end

  test "schemas/3 delegates the enriched schemas when the generation token matches" do
    companion = Generated.companion(ToolCall.GeneratedTest.MatchingFixture)
    schemas = companion.__schemas__()

    refute schemas == @fallback_schemas
    assert Generated.schemas(companion, @generation, @fallback_schemas) == schemas
  end

  test "tools/3 and schemas/3 return the fallback when the generation token differs" do
    companion = Generated.companion(ToolCall.GeneratedTest.MatchingFixture)
    stale = @generation + 1

    assert Generated.tools(companion, stale, @fallback_tools) == @fallback_tools
    assert Generated.schemas(companion, stale, @fallback_schemas) == @fallback_schemas
  end

  test "tools/3 and schemas/3 return the fallback when the companion is absent" do
    companion = Generated.companion(ToolCall.GeneratedTest.AbsentFixture)

    refute Code.ensure_loaded?(companion)

    assert Generated.tools(companion, 1, @fallback_tools) == @fallback_tools
    assert Generated.schemas(companion, 1, @fallback_schemas) == @fallback_schemas
  end

  test "tools/3 and schemas/3 return the fallback when the companion has no generation token" do
    companion = ToolCall.GeneratedTest.UnstampedCompanion

    assert Generated.tools(companion, 1, @fallback_tools) == @fallback_tools
    assert Generated.schemas(companion, 1, @fallback_schemas) == @fallback_schemas
  end

  test "tools/3 and schemas/3 fall back per function when the companion omits it" do
    tools_only = ToolCall.GeneratedTest.ToolsOnlyCompanion
    tools = tools_only.__tools__()

    assert Generated.tools(tools_only, 7, @fallback_tools) == tools
    assert Generated.schemas(tools_only, 7, @fallback_schemas) == @fallback_schemas

    schemas_only = ToolCall.GeneratedTest.SchemasOnlyCompanion
    schemas = schemas_only.__schemas__()

    assert Generated.schemas(schemas_only, 11, @fallback_schemas) == schemas
    assert Generated.tools(schemas_only, 11, @fallback_tools) == @fallback_tools
  end
end
