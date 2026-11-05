defmodule ToolCall.GeneratedTest.MatchingFixture do
  @moduledoc false
  # Phase-one module stand-in; its enriched companion is derived by
  # ToolCall.Generated.companion/1.
end

# `MatchingFixture.__ToolCall__` is not a valid alias (segments start with an
# uppercase letter), so the companion is defined with its full atom name.
defmodule :"Elixir.ToolCall.GeneratedTest.MatchingFixture.__ToolCall__" do
  @moduledoc false

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
  def __fingerprint__, do: :erlang.phash2({@tools, @schemas})
end

defmodule ToolCall.GeneratedTest.UnfingerprintedCompanion do
  @moduledoc false

  @tools [%ToolCall.IR.Tool{name: "unfingerprinted"}]

  def __tools__, do: @tools
  def __schemas__, do: %{}
end

defmodule ToolCall.GeneratedTest.ToolsOnlyCompanion do
  @moduledoc false

  @tools [%ToolCall.IR.Tool{name: "tools_only"}]

  def __tools__, do: @tools
  def __fingerprint__, do: 7
end

defmodule ToolCall.GeneratedTest.SchemasOnlyCompanion do
  @moduledoc false

  @schemas %{{:openai, false} => [%{"type" => "function", "name" => "schemas_only"}]}

  def __schemas__, do: @schemas
  def __fingerprint__, do: 11
end

defmodule ToolCall.GeneratedTest do
  use ExUnit.Case, async: true

  alias ToolCall.Generated
  alias ToolCall.IR.Tool

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

  test "fingerprint/2 hashes the tools and schemas pair" do
    fingerprint = Generated.fingerprint(@fallback_tools, @fallback_schemas)

    assert fingerprint == :erlang.phash2({@fallback_tools, @fallback_schemas})
    assert fingerprint >= 0

    refute fingerprint == Generated.fingerprint(@fallback_tools, %{})
    refute fingerprint == Generated.fingerprint([], @fallback_schemas)
  end

  test "tools/3 delegates to a companion with a matching fingerprint" do
    companion = Generated.companion(ToolCall.GeneratedTest.MatchingFixture)
    tools = companion.__tools__()
    fingerprint = Generated.fingerprint(tools, companion.__schemas__())

    assert Generated.tools(companion, fingerprint, @fallback_tools) == tools
  end

  test "schemas/3 delegates to a companion with a matching fingerprint" do
    companion = Generated.companion(ToolCall.GeneratedTest.MatchingFixture)
    schemas = companion.__schemas__()
    fingerprint = Generated.fingerprint(companion.__tools__(), schemas)

    assert Generated.schemas(companion, fingerprint, @fallback_schemas) == schemas
  end

  test "tools/3 and schemas/3 return the fallback when the fingerprint differs" do
    companion = Generated.companion(ToolCall.GeneratedTest.MatchingFixture)
    stale = Generated.fingerprint(@fallback_tools, @fallback_schemas)

    refute stale == Generated.fingerprint(companion.__tools__(), companion.__schemas__())

    assert Generated.tools(companion, stale, @fallback_tools) == @fallback_tools
    assert Generated.schemas(companion, stale, @fallback_schemas) == @fallback_schemas
  end

  test "tools/3 and schemas/3 return the fallback when the companion is absent" do
    companion = Generated.companion(ToolCall.GeneratedTest.AbsentFixture)

    refute Code.ensure_loaded?(companion)

    assert Generated.tools(companion, 0, @fallback_tools) == @fallback_tools
    assert Generated.schemas(companion, 0, @fallback_schemas) == @fallback_schemas
  end

  test "tools/3 and schemas/3 return the fallback when the companion has no fingerprint" do
    companion = ToolCall.GeneratedTest.UnfingerprintedCompanion

    assert Generated.tools(companion, 0, @fallback_tools) == @fallback_tools
    assert Generated.schemas(companion, 0, @fallback_schemas) == @fallback_schemas
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
