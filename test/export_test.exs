defmodule ToolCall.ExportTest do
  use ExUnit.Case, async: false

  @moduletag :export

  import ExUnit.CaptureIO
  import ToolCall.TestModule

  defp export(args) do
    Mix.Task.reenable("tool_call.export")
    capture_io(fn -> Mix.Task.run("tool_call.export", args) end)
  end

  defp tool_module(fun) do
    compile!("""
    defmodule FIXTURE do
      use ToolCall

      @doc "Tool #{fun}."
      @spec #{fun}(a :: String.t()) :: String.t()
      def #{fun}(a), do: a
    end
    """)
  end

  defp weather do
    compile!("""
    defmodule FIXTURE do
      use ToolCall

      @doc "Get the forecast."
      @spec get_weather(city :: String.t(), days :: pos_integer()) :: String.t()
      def get_weather(city, _days \\\\ 3), do: city
    end
    """)
  end

  test "exports OpenAI function objects by default" do
    module = weather()

    assert [%{"type" => "function", "function" => function}] =
             JSON.decode!(export([inspect(module)]))

    assert function["name"] == "get_weather"
    assert function["parameters"]["properties"]["city"] == %{"type" => "string"}
  end

  test "exports Anthropic tool definitions" do
    module = weather()

    assert [%{"name" => "get_weather", "input_schema" => %{"type" => "object"}}] =
             JSON.decode!(export([inspect(module), "--format", "anthropic"]))
  end

  test "exports an MCP tools/list result" do
    module = weather()

    assert %{"tools" => [%{"name" => "get_weather", "inputSchema" => %{"type" => "object"}}]} =
             JSON.decode!(export([inspect(module), "--format", "mcp"]))
  end

  test "passes --strict through to the schema" do
    module = weather()

    assert [tool] = JSON.decode!(export([inspect(module), "--strict"]))
    assert tool["strict"] == true
    assert tool["function"]["parameters"]["required"] == ["city", "days"]
  end

  @tag :tmp_dir
  test "writes to --out", %{tmp_dir: dir} do
    module = weather()
    path = Path.join([dir, "priv", "tools.json"])

    export([inspect(module), "--out", path])
    export([inspect(module), "--out", path])

    assert [%{"type" => "function"}] = path |> File.read!() |> JSON.decode!()
    assert Path.wildcard("#{path}.tmp.*") == []
  end

  @tag :tmp_dir
  test "cleans up the temp file when the target cannot be replaced", %{tmp_dir: dir} do
    module = weather()
    path = Path.join([dir, "tools.json"])
    File.mkdir_p!(path)

    assert_raise File.RenameError, fn -> export([inspect(module), "--out", path]) end
    assert Path.wildcard("#{path}.tmp.*") == []
  end

  test "prints indented JSON by default" do
    module = weather()
    json = export([inspect(module)])

    assert json =~ ~s(\n    "function": {)
    assert json =~ ~s("description": "Get the forecast.")
    assert [%{"type" => "function"}] = JSON.decode!(json)
  end

  test "sorts keys even for maps that are not flatmaps" do
    params = Enum.map_join(0..32, ", ", &"p#{&1} :: String.t()")
    args = Enum.map_join(0..32, ", ", &"p#{&1}")

    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @spec wide(#{params}) :: :ok
        def wide(#{args}), do: :ok
      end
      """)

    json = export([inspect(module)])

    keys =
      ~r/"p(\d+)":/
      |> Regex.scan(json, capture: :all_but_first)
      |> List.flatten()

    assert Enum.count(keys) == 33
    assert keys == Enum.sort(keys)
  end

  test "keeps strings intact" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @doc ~S(Braces {,} and a "quote" and ünïcode.)
        @spec echo(text :: String.t()) :: String.t()
        def echo(text), do: text
      end
      """)

    description =
      export([inspect(module)])
      |> JSON.decode!()
      |> hd()
      |> get_in(["function", "description"])

    assert description == ~S(Braces {,} and a "quote" and ünïcode.)
  end

  test "encodes nil inside a default as JSON null" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @spec go(xs :: list()) :: list()
        def go(xs \\\\ [nil]), do: xs
      end
      """)

    assert [tool] = JSON.decode!(export([inspect(module)]))
    assert tool["function"]["parameters"]["properties"]["xs"]["default"] == [nil]
  end

  test "sorts modules so the output is reproducible" do
    first = tool_module("zeta")
    second = tool_module("alpha")

    expected =
      [first, second]
      |> Enum.sort_by(&Atom.to_string/1)
      |> Enum.map(&(&1.__tools__() |> hd() |> Map.fetch!(:name)))

    names =
      export([inspect(first), inspect(second)])
      |> JSON.decode!()
      |> Enum.map(& &1["function"]["name"])

    assert names == expected
  end

  test "rejects an unknown format" do
    module = weather()

    assert_raise Mix.Error, ~r/unknown format/, fn ->
      export([inspect(module), "--format", "nope"])
    end
  end

  test "rejects a module that does not use ToolCall" do
    assert_raise Mix.Error, ~r/String does not use ToolCall/, fn -> export(["String"]) end
  end

  test "rejects duplicate tool names across modules" do
    first = tool_module("same")
    second = tool_module("same")

    assert_raise Mix.Error, ~r/unique/, fn -> export([inspect(first), inspect(second)]) end
  end

  test "refuses tool names the providers reject" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Bad name."
        @spec find?(id :: integer()) :: integer()
        def find?(id), do: id
      end
      """)

    assert_raise Mix.Error, ~r/tool names must match/, fn -> export([inspect(module)]) end
  end

  test "discovers the tools of --app" do
    assert_raise Mix.Error, ~r/no modules in :tool_call use ToolCall/, fn ->
      export(["--app", "tool_call"])
    end
  end

  @tag :tmp_dir
  test "discovers tools in an application it loads", %{tmp_dir: dir} do
    module = tool_module("demo")
    app = :tool_call_demo
    ebin = Path.join([dir, "ebin"])
    File.mkdir_p!(ebin)

    spec =
      {:application, app,
       [
         description: ~c"demo",
         vsn: ~c"0.1.0",
         modules: [module],
         registered: [],
         applications: [:kernel, :stdlib]
       ]}

    File.write!(Path.join(ebin, "tool_call_demo.app"), :io_lib.format("~p.~n", [spec]))
    Code.prepend_path(ebin)

    try do
      json = export(["--app", "tool_call_demo"])
      assert [%{"function" => %{"name" => "demo"}}] = JSON.decode!(json)
    after
      Application.unload(app)
      Code.delete_path(ebin)
    end
  end

  test "requires an application when there is no project" do
    project = Mix.Project.get()
    Mix.Project.pop()

    try do
      assert_raise Mix.Error, ~r/no application to discover/, fn ->
        Mix.Tasks.ToolCall.Export.run([])
      end
    after
      Mix.Project.push(project)
    end
  end

  test "re-raises a rename error that is not eexist" do
    rename = fn source, destination ->
      raise File.RenameError,
        reason: :eacces,
        source: source,
        destination: destination,
        action: "rename"
    end

    assert_raise File.RenameError, fn ->
      Mix.Tasks.ToolCall.Export.replace("tmp", "target", rename)
    end
  end

  @tag :tmp_dir
  test "retries when the platform refuses to replace an existing target", %{tmp_dir: dir} do
    tmp = Path.join(dir, "tmp")
    path = Path.join(dir, "target")
    File.write!(tmp, "new")
    File.write!(path, "old")
    parent = self()

    rename = fn source, destination ->
      case Process.get(:tc_rename_attempt) do
        nil ->
          Process.put(:tc_rename_attempt, 1)
          send(parent, {:attempt, source, destination})

          raise File.RenameError,
            reason: :eexist,
            source: source,
            destination: destination,
            action: "rename"

        _attempt ->
          File.rename!(source, destination)
      end
    end

    assert :ok = Mix.Tasks.ToolCall.Export.replace(tmp, path, rename)
    assert_received {:attempt, ^tmp, ^path}
    assert File.read!(path) == "new"
    refute File.exists?(tmp)
  end

  test "rejects an app it cannot load" do
    assert_raise Mix.Error, ~r/cannot load :nope/, fn -> export(["--app", "nope"]) end
  end

  test "fails when the given modules export no tools" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @doc false
        @spec hidden(a :: String.t()) :: String.t()
        def hidden(a), do: a
      end
      """)

    assert_raise Mix.Error, ~r/no tools found/, fn -> export([inspect(module)]) end
  end

  test "fails when the application has no tool modules" do
    assert_raise Mix.Error, ~r/no modules in :tool_call use ToolCall/, fn -> export([]) end
  end
end
