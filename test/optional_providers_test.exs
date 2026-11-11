defmodule ToolCall.OptionalProvidersTest do
  use ExUnit.Case, async: true

  import ToolCall.TestModule

  defp uri_module do
    compile!("""
    defmodule FIXTURE do
      use ToolCall, types: [ToolCall.Providers.URI]

      @doc "Fetch a URI."
      @spec fetch(url :: URI.t()) :: URI.t()
      def fetch(url), do: url

      @doc "Return the wrong shape."
      @spec bad() :: URI.t()
      def bad, do: "not a uri"
    end
    """)
  end

  defp version_module do
    compile!("""
    defmodule FIXTURE do
      use ToolCall, types: [ToolCall.Providers.Version]

      @doc "Echo a version."
      @spec bump(version :: Version.t()) :: Version.t()
      def bump(version), do: version

      @doc "Return the wrong shape."
      @spec bad() :: Version.t()
      def bad, do: "1.2.3"
    end
    """)
  end

  test "URI uses a string wire form and returns a struct" do
    module = uri_module()

    [tool] = ToolCall.tools(module) |> Enum.filter(&(&1.name == "fetch"))
    assert tool.params |> hd() |> Map.fetch!(:type) |> Map.fetch!(:kind) == :string

    assert get_in(ToolCall.emit(module, :openai), [
             Access.at(0),
             "function",
             "parameters",
             "properties",
             "url",
             "type"
           ]) == "string"

    assert {:ok, %URI{} = uri} =
             ToolCall.run(module, :fetch, %{"url" => "https://example.com/path?q=1"})

    assert URI.to_string(uri) == "https://example.com/path?q=1"

    assert {:error, {:invalid_argument, {"url", {:invalid_uri, _reason}}}} =
             ToolCall.run(module, :fetch, %{"url" => "not a uri"})
  end

  test "URI result validation uses the struct value domain" do
    module = uri_module()

    assert {:ok, %URI{}} =
             ToolCall.run(module, :fetch, %{"url" => "https://example.com"},
               validate_result: true
             )

    assert {:error, {:invalid_result, _reason}} =
             ToolCall.run(module, :bad, %{}, validate_result: true)
  end

  test "Version uses a string wire form and returns a struct" do
    module = version_module()

    [tool] = ToolCall.tools(module) |> Enum.filter(&(&1.name == "bump"))
    assert tool.params |> hd() |> Map.fetch!(:type) |> Map.fetch!(:kind) == :string

    assert get_in(ToolCall.emit(module, :openai), [
             Access.at(0),
             "function",
             "parameters",
             "properties",
             "version",
             "type"
           ]) == "string"

    assert {:ok, %Version{major: 1, minor: 2, patch: 3, pre: ["rc", 1], build: "build"}} =
             ToolCall.run(module, :bump, %{"version" => "1.2.3-rc.1+build"})

    assert {:error, {:invalid_argument, {"version", {:invalid_version, "1.2"}}}} =
             ToolCall.run(module, :bump, %{"version" => "1.2"})
  end

  test "Version result validation uses the struct value domain" do
    module = version_module()

    assert {:ok, %Version{}} =
             ToolCall.run(module, :bump, %{"version" => "1.2.3"}, validate_result: true)

    assert {:error, {:invalid_result, _reason}} =
             ToolCall.run(module, :bad, %{}, validate_result: true)
  end

  test "URI and Version providers are opt-in" do
    refute ToolCall.Providers.URI in ToolCall.Typespec.builtin_providers()
    refute ToolCall.Providers.Version in ToolCall.Typespec.builtin_providers()
  end
end
