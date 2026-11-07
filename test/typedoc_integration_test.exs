defmodule ToolCall.TypedocIntegrationTest.NoAppProject do
  @moduledoc false
  def project, do: [version: "0.0.0"]
end

defmodule ToolCall.TypedocIntegrationTest.AfterCompileProbe do
  @moduledoc false
  # Runs before ToolCall's own callback when a fixture declares it first, so a
  # test can feed ToolCall.__after_compile__ a damaged beam while the phase-one
  # snapshot is still readable.

  def __after_compile__(env, bytecode) do
    case :persistent_term.get({__MODULE__, :transform}, :none) do
      :none -> :ok
      transform -> ToolCall.__after_compile__(env, transform.(bytecode))
    end
  end
end

defmodule ToolCall.TypedocIntegrationTest.RaisingCompanion do
  @moduledoc false

  def __tool_call_companion__, do: raise("marker exploded")
end

defmodule ToolCall.TypedocIntegrationTest do
  # These tests toggle the global :docs compiler option and one writes into the
  # project compile path, so they must not run concurrently with other modules.
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  import ToolCall.TestModule, only: [compile_with_diagnostics!: 1]

  alias ToolCall.Generated
  alias ToolCall.IR.{Param, Tool}

  @typedoc_source """
  defmodule FIXTURE do
    use ToolCall

    @typedoc "Postal address"
    @type address :: String.t()

    @doc "Send a parcel."
    @spec send(to :: address()) :: :ok
    def send(_to), do: :ok
  end
  """

  @plain_source """
  defmodule FIXTURE do
    use ToolCall

    @type address :: String.t()

    @doc "Send a parcel."
    @spec send(to :: address()) :: :ok
    def send(_to), do: :ok
  end
  """

  test "@opaque typedoc fills an unannotated parameter description" do
    module =
      compile_with_docs!("""
      defmodule FIXTURE do
        use ToolCall

        @typedoc "Opaque postal address"
        @opaque address :: String.t()

        @doc "Send a parcel."
        @spec send(to :: address()) :: :ok
        def send(_to), do: :ok
      end
      """)

    on_exit(fn -> unload(module) end)

    assert param_description(module, "send", "to") == "Opaque postal address"
  end

  test "a when constraint over a local type takes its typedoc" do
    module =
      compile_with_docs!("""
      defmodule FIXTURE do
        use ToolCall

        @typedoc "Postal address"
        @type address :: String.t()

        @doc "Send a parcel."
        @spec send(where :: to) :: :ok when to: address()
        def send(_to), do: :ok
      end
      """)

    on_exit(fn -> unload(module) end)

    assert param_description(module, "send", "where") == "Postal address"
  end

  test "__MODULE__ local type references take their typedoc" do
    module =
      compile_with_docs!("""
      defmodule FIXTURE do
        use ToolCall

        @typedoc "Postal address"
        @type address :: String.t()

        @doc "Send a parcel."
        @spec send(to :: __MODULE__.address()) :: :ok
        def send(_to), do: :ok
      end
      """)

    on_exit(fn -> unload(module) end)

    assert param_description(module, "send", "to") == "Postal address"
  end

  test "fully qualified current-module local types take their typedoc" do
    module =
      compile_with_docs!("""
      defmodule FIXTURE do
        use ToolCall

        @typedoc "Postal address"
        @type address :: String.t()

        @doc "Send a parcel."
        @spec send(to :: FIXTURE.address()) :: :ok
        def send(_to), do: :ok
      end
      """)

    on_exit(fn -> unload(module) end)

    assert param_description(module, "send", "to") == "Postal address"
  end

  test "aliases to the current module keep local typedoc" do
    module =
      compile_with_docs!("""
      defmodule FIXTURE do
        use ToolCall

        alias FIXTURE, as: Self

        @typedoc "Postal address"
        @type address :: String.t()

        @doc "Send a parcel."
        @spec send(to :: Self.address()) :: :ok
        def send(_to), do: :ok
      end
      """)

    on_exit(fn -> unload(module) end)

    assert param_description(module, "send", "to") == "Postal address"
  end

  test "@typedoc false is hidden and creates no companion" do
    {module, binary} =
      compile_with_docs_and_bytecode!("""
      defmodule FIXTURE do
        use ToolCall

        @typedoc false
        @type address :: String.t()

        @doc "Send a parcel."
        @spec send(to :: address()) :: :ok
        def send(_to), do: :ok
      end
      """)

    on_exit(fn -> unload(module) end)

    assert param_description(module, "send", "to") == nil
    refute Code.ensure_loaded?(Generated.companion(module))
    # Phase one cannot know that the type's docs are hidden, so the key exists
    # and the accessor stays guarded.
    assert guarded_call?(binary, :__tools__, :tools)
    assert guarded_call?(binary, :__schemas__, :schemas)
  end

  test "a docs-disabled compile skips typedoc without warning" do
    {module, diagnostics} = compile_with_docs_and_diagnostics!(@typedoc_source, false)

    on_exit(fn -> unload(module) end)

    assert diagnostics == []
    assert param_description(module, "send", "to") == nil
    refute Code.ensure_loaded?(Generated.companion(module))
  end

  test "a missing Docs chunk warns when docs are enabled" do
    {module, diagnostics} =
      compile_with_after_compile_probe!(
        fn bytecode -> strip_chunk(bytecode, ~c"Docs") end,
        @typedoc_source
      )

    on_exit(fn -> unload(module) end)

    assert Enum.map_join(diagnostics, "\n", & &1.message) =~ "the Docs chunk is missing"
  end

  test "a structurally invalid Docs chunk warns as corrupt" do
    invalid = {:docs_v1, 0, :elixir, "text/markdown", :none, %{}, :not_a_list}

    {module, diagnostics} =
      compile_with_after_compile_probe!(
        fn bytecode -> replace_chunk(bytecode, ~c"Docs", :erlang.term_to_binary(invalid)) end,
        @typedoc_source
      )

    on_exit(fn -> unload(module) end)

    assert Enum.map_join(diagnostics, "\n", & &1.message) =~
             "could not be decoded or has an unexpected structure"
  end

  test "an unreadable beam warns" do
    {module, diagnostics} =
      compile_with_after_compile_probe!(fn _bytecode -> <<1, 2, 3>> end, @typedoc_source)

    on_exit(fn -> unload(module) end)

    assert Enum.map_join(diagnostics, "\n", & &1.message) =~ "compiled beam could not be read"
  end

  test "an unexpected enrichment failure warns instead of failing the compile" do
    {module, diagnostics} =
      compile_with_after_compile_probe!(fn _bytecode -> :not_a_binary end, @typedoc_source)

    on_exit(fn -> unload(module) end)

    assert Enum.map_join(diagnostics, "\n", & &1.message) =~ "typedoc enrichment failed"
  end

  test "an empty typedoc key map skips the Docs chunk and removes a stale companion" do
    module = Module.concat([__MODULE__, "EmptyKeys#{System.unique_integer([:positive])}"])
    companion = Generated.companion(module)

    on_exit(fn ->
      purge(module)
      purge(companion)
    end)

    assert Generated.create(env("nofile"), companion, [], %{}, 1) == :ok
    assert Code.ensure_loaded?(companion)

    source = """
    defmodule #{inspect(module)} do
      use ToolCall

      @doc "Ping."
      @spec ping() :: :ok
      def ping, do: :ok
    end
    """

    {^module, diagnostics} = compile_with_docs_and_diagnostics!(source, false)

    assert diagnostics == []
    refute Code.ensure_loaded?(companion)
  end

  test "a user-defined companion module is not overwritten or unloaded" do
    module = Module.concat([__MODULE__, "Collision#{System.unique_integer([:positive])}"])
    companion = Generated.companion(module)
    companion_name = Atom.to_string(companion)

    source = """
    defmodule :#{inspect(companion_name)} do
      def __tool_call_companion__, do: false
      def user_marker, do: :kept
    end

    defmodule #{inspect(module)} do
      use ToolCall

      @typedoc "Postal address"
      @type address :: String.t()

      @doc "Send a parcel."
      @spec send(to :: address()) :: :ok
      def send(_to), do: :ok
    end
    """

    {_module, diagnostics} = compile_with_docs_and_diagnostics!(source)

    on_exit(fn ->
      purge(module)
      purge(companion)
    end)

    warning = Enum.map_join(diagnostics, "\n", & &1.message)

    assert warning =~ "was not generated by ToolCall"
    assert companion.user_marker() == :kept
    refute function_exported?(companion, :__tools__, 0)
    assert param_description(module, "send", "to") == nil

    assert Generated.remove(env("lib/collision.ex"), companion) == :ok
    assert companion.user_marker() == :kept
  end

  test "a user-defined companion beam is not overwritten" do
    companion = synthetic_companion("ForeignBeam")
    beam = beam_path(companion)
    File.write!(beam, user_companion_beam(companion))

    on_exit(fn ->
      File.rm(beam)
      purge(companion)
    end)

    warning =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert Generated.create(env("lib/foreign_beam.ex"), companion, [], %{}, 1) == :error
      end)

    assert warning =~ "was not generated by ToolCall"
    assert :code.is_loaded(companion) == false
    assert {:user_marker, 0} in beam_exports(beam)
    refute {:__tools__, 0} in beam_exports(beam)
  end

  test "a local @typedoc fills unannotated parameter descriptions everywhere" do
    module = compile_with_docs!(@typedoc_source)
    on_exit(fn -> unload(module) end)

    assert [%Tool{name: "send", params: [%Param{name: "to", description: "Postal address"}]}] =
             ToolCall.tools(module)

    assert [%{name: "send", parameters: parameters}] = ToolCall.describe(module)
    assert parameters["properties"]["to"]["description"] == "Postal address"

    assert schema_value(module, :openai, ["parameters", "properties", "to", "description"]) ==
             "Postal address"

    assert schema_value(module, :anthropic, ["properties", "to", "description"]) ==
             "Postal address"
  end

  test "@doc parameter bullets and @tool_param descriptions override typedoc" do
    module =
      compile_with_docs!("""
      defmodule FIXTURE do
        use ToolCall

        @typedoc "Postal address"
        @type address :: String.t()

        @doc \"\"\"
        Send a parcel.

        ## Parameters
          * `to` - from the doc
        \"\"\"
        @spec send(to :: address()) :: :ok
        def send(_to), do: :ok

        @tool_param %{fun: :ship, name: "to", description: "from the override"}
        @spec ship(to :: address()) :: :ok
        def ship(_to), do: :ok

        @tool_param %{fun: :clear, name: "to", description: ""}
        @spec clear(to :: address()) :: :ok
        def clear(_to), do: :ok
      end
      """)

    on_exit(fn -> unload(module) end)

    assert param_description(module, "send", "to") == "from the doc"
    assert param_description(module, "ship", "to") == "from the override"
    assert param_description(module, "clear", "to") == ""
  end

  test "nullable local types take their typedoc, list local types do not" do
    module =
      compile_with_docs!("""
      defmodule FIXTURE do
        use ToolCall

        @typedoc "Postal address"
        @type address :: String.t()

        @doc "Send a parcel."
        @spec send(to :: address() | nil, all :: list(address())) :: :ok
        def send(_to, _all), do: :ok
      end
      """)

    on_exit(fn -> unload(module) end)

    assert param_description(module, "send", "to") == "Postal address"
    assert param_description(module, "send", "all") == nil
  end

  test "local alias chains resolve current-module references" do
    module =
      compile_with_docs!("""
      defmodule FIXTURE do
        use ToolCall

        @typedoc "Postal address"
        @type address :: String.t()

        @type location :: __MODULE__.address()

        @doc "Send a parcel."
        @spec send(to :: location()) :: :ok
        def send(_to), do: :ok
      end
      """)

    on_exit(fn -> unload(module) end)

    assert param_description(module, "send", "to") == "Postal address"
  end

  test "local alias chains take the nearest typedoc" do
    module =
      compile_with_docs!("""
      defmodule FIXTURE do
        use ToolCall

        @typedoc "Postal address"
        @type address :: String.t()

        @type location :: address()

        @doc "Send a parcel."
        @spec send(to :: location()) :: :ok
        def send(_to), do: :ok
      end
      """)

    on_exit(fn -> unload(module) end)

    assert param_description(module, "send", "to") == "Postal address"
  end

  test "parameterized local types take their typedoc" do
    module =
      compile_with_docs!("""
      defmodule FIXTURE do
        use ToolCall

        @typedoc "Pair of values"
        @type pair(a) :: {a, a}

        @doc "Send a pair."
        @spec send(value :: pair(integer())) :: :ok
        def send(_value), do: :ok
      end
      """)

    on_exit(fn -> unload(module) end)

    assert param_description(module, "send", "value") == "Pair of values"
  end

  test "@typep typedoc is ignored" do
    module =
      compile_with_docs!("""
      defmodule FIXTURE do
        use ToolCall

        @typedoc "Hidden"
        @typep secret :: String.t()

        @doc "Reveal it."
        @spec reveal(value :: secret()) :: String.t()
        def reveal(value), do: value
      end
      """)

    on_exit(fn -> unload(module) end)

    assert param_description(module, "reveal", "value") == nil
    refute Code.ensure_loaded?(Generated.companion(module))
  end

  test "a module without typedoc has no companion and unchanged output" do
    module = compile_with_docs!(@plain_source)
    control = compile_with_docs!(@plain_source, false)
    on_exit(fn -> unload(module) end)
    on_exit(fn -> unload(control) end)

    refute Code.ensure_loaded?(Generated.companion(module))
    assert param_description(module, "send", "to") == nil

    assert ToolCall.emit(module, :openai) == ToolCall.emit(control, :openai)
    assert ToolCall.emit(module, :anthropic) == ToolCall.emit(control, :anthropic)
  end

  test "a module without local-type keys embeds direct accessor literals" do
    {module, binary} =
      compile_with_docs_and_bytecode!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Send a parcel."
        @spec send(to :: String.t()) :: :ok
        def send(_to), do: :ok
      end
      """)

    on_exit(fn -> unload(module) end)

    refute Code.ensure_loaded?(Generated.companion(module))
    assert direct_literal?(binary, :__tools__)
    assert direct_literal?(binary, :__schemas__)
  end

  test "a documented local-type parameter embeds direct accessor literals" do
    {module, binary} =
      compile_with_docs_and_bytecode!("""
      defmodule FIXTURE do
        use ToolCall

        @typedoc "Postal address"
        @type address :: String.t()

        @doc \"\"\"
        Send a parcel.

        ## Parameters
          * `to` - where it goes
        \"\"\"
        @spec send(to :: address()) :: :ok
        def send(_to), do: :ok
      end
      """)

    on_exit(fn -> unload(module) end)

    refute Code.ensure_loaded?(Generated.companion(module))
    assert direct_literal?(binary, :__tools__)
    assert direct_literal?(binary, :__schemas__)
  end

  test "a docs-disabled build embeds direct accessor literals" do
    {module, binary} = compile_with_docs_and_bytecode!(@typedoc_source, false)
    on_exit(fn -> unload(module) end)

    refute Code.ensure_loaded?(Generated.companion(module))
    assert direct_literal?(binary, :__tools__)
    assert direct_literal?(binary, :__schemas__)
  end

  test "a module with typedoc keys calls the guarded companion helper" do
    {module, binary} = compile_with_docs_and_bytecode!(@typedoc_source)
    on_exit(fn -> unload(module) end)

    assert guarded_call?(binary, :__tools__, :tools)
    assert guarded_call?(binary, :__schemas__, :schemas)
  end

  test "Code.compile_string creates only an in-memory companion" do
    module = compile_with_docs!(@typedoc_source)
    companion = Generated.companion(module)
    on_exit(fn -> unload(module) end)

    assert Code.ensure_loaded?(companion)
    assert param_description(module, "send", "to") == "Postal address"
    refute File.exists?(companion_beam(module))
  end

  test "a stale companion generation token falls back to phase-one data" do
    module = compile_with_docs!(@typedoc_source)
    companion = Generated.companion(module)
    on_exit(fn -> unload(module) end)

    assert param_description(module, "send", "to") == "Postal address"

    purge(companion)
    fallback_tools = module.__tools__()
    fallback_schemas = module.__schemas__()
    assert tools_param_description(fallback_tools, "send", "to") == nil

    stale_tools = [
      %Tool{
        name: "send",
        description: "stale",
        module: module,
        fun: :send,
        params: [%Param{name: "to", description: "stale"}]
      }
    ]

    create_stale_companion(companion, stale_tools, %{})

    assert module.__tools__() == fallback_tools
    assert module.__schemas__() == fallback_schemas
  end

  test "a source-file module persists its companion until typedoc stops applying" do
    path = write_temp_source!(@typedoc_source)
    on_exit(fn -> File.rm(path) end)

    module = compile_file_with_docs!(path)
    on_exit(fn -> unload(module) end)

    companion = Generated.companion(module)
    beam = companion_beam(module)

    assert File.exists?(beam)
    assert param_description(module, "send", "to") == "Postal address"

    purge(companion)
    assert Code.ensure_loaded?(companion)
    assert param_description(module, "send", "to") == "Postal address"

    File.write!(path, String.replace(@plain_source, "FIXTURE", inspect(module)))
    assert compile_file_with_docs!(path) == module

    refute File.exists?(beam)
    refute Code.ensure_loaded?(companion)
    assert param_description(module, "send", "to") == nil
  end

  test "a failed companion write warns and leaves phase-one data in place" do
    companion = synthetic_companion("WriteFailure")
    # A directory at the beam path makes the atomic rename fail like a
    # permission or filesystem error, without changing the compile path.
    beam = beam_path(companion)
    File.mkdir_p!(beam)

    on_exit(fn ->
      File.rm_rf(beam)
      purge(companion)
    end)

    warning =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert Generated.create(env("lib/write_failure.ex"), companion, [], %{}, 1) == :error
      end)

    assert warning =~ "could not write the typedoc companion beam"
    assert :code.is_loaded(companion) == false
  end

  test "a companion that cannot be created warns and fails for both storage modes" do
    memory = synthetic_companion("UnescapableMemory")
    persisted = synthetic_companion("UnescapablePersisted")

    on_exit(fn ->
      purge(memory)
      purge(persisted)
    end)

    for {file, companion} <- [{"nofile", memory}, {"lib/unescapable.ex", persisted}] do
      warning =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          # A reference is a valid term but not escapable into generated code.
          assert Generated.create(env(file), companion, [make_ref()], %{}, 1) == :error
        end)

      assert warning =~ "could not create the typedoc companion"
      refute Code.ensure_loaded?(companion)
    end
  end

  test "an unreadable companion beam is treated as foreign" do
    companion = synthetic_companion("CorruptBeam")
    beam = beam_path(companion)
    File.write!(beam, "not a beam")

    on_exit(fn ->
      File.rm(beam)
      purge(companion)
    end)

    warning =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert Generated.create(env("lib/corrupt_beam.ex"), companion, [], %{}, 1) == :error
      end)

    assert warning =~ "was not generated by ToolCall"
    assert File.read!(beam) == "not a beam"
    refute Code.ensure_loaded?(companion)
  end

  test "remove deletes an unloaded companion beam" do
    companion = synthetic_companion("UnloadedRemove")
    beam = beam_path(companion)

    on_exit(fn ->
      File.rm(beam)
      purge(companion)
    end)

    assert Generated.create(env("lib/unloaded_remove.ex"), companion, [], %{}, 1) == :ok
    assert File.exists?(beam)

    purge(companion)
    assert Generated.remove(env("lib/unloaded_remove.ex"), companion) == :ok

    refute File.exists?(beam)
    refute Code.ensure_loaded?(companion)
  end

  test "a loaded module whose companion marker raises is treated as foreign" do
    companion = ToolCall.TypedocIntegrationTest.RaisingCompanion

    assert Generated.remove(env("lib/raising_companion.ex"), companion) == :ok
    assert Code.ensure_loaded?(companion)

    assert_raise RuntimeError, "marker exploded", fn ->
      companion.__tool_call_companion__()
    end
  end

  test "a missing Mix compile path warns and skips the companion" do
    # No project and a project without an :app both make compile_path/0
    # unavailable; the second takes the compile_path/0 rescue branch.
    project = Mix.Project.pop()
    no_project = synthetic_companion("NoProject")
    no_app = synthetic_companion("NoApp")

    try do
      warning =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert Generated.create(env("lib/no_project.ex"), no_project, [], %{}, 1) == :error
        end)

      assert warning =~ "Mix.Project.compile_path/0 is unavailable"

      :ok = Mix.Project.push(ToolCall.TypedocIntegrationTest.NoAppProject)

      warning =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert Generated.create(env("lib/no_app.ex"), no_app, [], %{}, 1) == :error
        end)

      assert warning =~ "Mix.Project.compile_path/0 is unavailable"
    after
      _ = Mix.Project.pop()
      :ok = Mix.Project.push(project.name, project[:file], project[:app])
    end

    refute Code.ensure_loaded?(no_project)
    refute Code.ensure_loaded?(no_app)
  end

  test "__after_compile__/2 ignores a module that does not use ToolCall" do
    module = synthetic_companion("NoSnapshot")

    {:module, ^module, _binary, _term} =
      Module.create(module, quote(do: @after_compile(ToolCall)), file: "nofile", line: 1)

    on_exit(fn -> purge(module) end)
  end

  defp synthetic_companion(label) do
    Module.concat([__MODULE__, "#{label}#{System.unique_integer([:positive])}"])
  end

  defp env(file), do: %{file: file, line: 1}

  defp compile_with_docs!(source, enabled? \\ true) do
    {module, _diagnostics} = compile_with_docs_and_diagnostics!(source, enabled?)
    module
  end

  defp compile_with_docs_and_bytecode!(source, enabled? \\ true) do
    previous_docs = Code.compiler_options()[:docs]
    previous_debug_info = Code.compiler_options()[:debug_info]
    Code.compiler_options(docs: enabled?, debug_info: true)

    try do
      name = "Fixture#{System.unique_integer([:positive])}"

      {[{module, binary} | _], _diagnostics} =
        Code.with_diagnostics(fn ->
          Code.compile_string(String.replace(source, "FIXTURE", name))
        end)

      {module, binary}
    after
      Code.compiler_options(docs: previous_docs, debug_info: previous_debug_info)
    end
  end

  defp direct_literal?(binary, function) do
    body = function_body(binary, function)
    not contains_call?(body)
  end

  defp guarded_call?(binary, function, helper) do
    body = function_body(binary, function)
    contains_remote_call?(body, Generated, helper)
  end

  defp function_body(binary, function) do
    {:ok, {_module, [abstract_code: {:raw_abstract_v1, forms}]}} =
      :beam_lib.chunks(binary, [:abstract_code])

    {:function, _line, ^function, 0, [{:clause, _meta, [], [], [body]}]} =
      Enum.find(forms, &match?({:function, _, ^function, 0, _}, &1))

    body
  end

  defp contains_call?({:call, _line, _callee, _args}), do: true

  defp contains_call?(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.any?(&contains_call?/1)

  defp contains_call?(list) when is_list(list), do: Enum.any?(list, &contains_call?/1)
  defp contains_call?(_other), do: false

  defp contains_remote_call?(
         {:call, _line,
          {:remote, _remote_line, {:atom, _, called_module}, {:atom, _, called_helper}}, _args},
         module,
         helper
       )
       when called_module == module and called_helper == helper,
       do: true

  defp contains_remote_call?(tuple, module, helper) when is_tuple(tuple),
    do:
      tuple
      |> Tuple.to_list()
      |> Enum.any?(&contains_remote_call?(&1, module, helper))

  defp contains_remote_call?(list, module, helper) when is_list(list),
    do: Enum.any?(list, &contains_remote_call?(&1, module, helper))

  defp contains_remote_call?(_other, _module, _helper), do: false

  defp compile_with_after_compile_probe!(transform, source, enabled? \\ true) do
    key = {ToolCall.TypedocIntegrationTest.AfterCompileProbe, :transform}
    :persistent_term.put(key, transform)
    on_exit(fn -> :persistent_term.erase(key) end)

    source =
      String.replace(
        source,
        "use ToolCall",
        "@after_compile ToolCall.TypedocIntegrationTest.AfterCompileProbe\n  use ToolCall",
        global: false
      )

    compile_with_docs_and_diagnostics!(source, enabled?)
  end

  defp compile_with_docs_and_diagnostics!(source, enabled? \\ true) do
    previous = Code.compiler_options()[:docs]
    Code.compiler_options(docs: enabled?)

    try do
      compile_with_diagnostics!(source)
    after
      Code.compiler_options(docs: previous)
    end
  end

  defp compile_file_with_docs!(path) do
    previous = Code.compiler_options()[:docs]
    Code.compiler_options(docs: true)

    try do
      {[{module, _binary} | _], _diagnostics} =
        Code.with_diagnostics(fn -> Code.compile_file(path) end)

      module
    after
      Code.compiler_options(docs: previous)
    end
  end

  defp write_temp_source!(source) do
    name = "ToolCallTypedocFileFixture#{System.unique_integer([:positive])}"
    path = Path.join(System.tmp_dir!(), "#{name}.ex")
    File.write!(path, String.replace(source, "FIXTURE", name))
    path
  end

  defp schema_value(module, :openai, path) do
    module |> ToolCall.emit(:openai) |> hd() |> get_in(["function" | path])
  end

  defp schema_value(module, :anthropic, path) do
    module |> ToolCall.emit(:anthropic) |> hd() |> get_in(["input_schema" | path])
  end

  defp param_description(module, tool_name, param_name) do
    module |> ToolCall.tools() |> tools_param_description(tool_name, param_name)
  end

  defp tools_param_description(tools, tool_name, param_name) do
    tool = Enum.find(tools, &(&1.name == tool_name))
    Enum.find(tool.params, &(&1.name == param_name)).description
  end

  defp companion_beam(module), do: module |> Generated.companion() |> beam_path()

  defp beam_path(companion) do
    Path.join(Mix.Project.compile_path(), Atom.to_string(companion) <> ".beam")
  end

  defp unload(module) do
    companion = Generated.companion(module)
    purge(companion)
    File.rm(companion_beam(module))
    :ok
  end

  defp purge(module) do
    :code.purge(module)
    :code.delete(module)
    :ok
  end

  defp user_companion_beam(module) do
    quoted =
      quote do
        def user_marker, do: :kept
      end

    {:module, ^module, binary, _term} =
      Module.create(module, quoted, file: "nofile", line: 1)

    purge(module)
    binary
  end

  defp beam_exports(path) do
    {:ok, {_module, [exports: exports]}} =
      :beam_lib.chunks(String.to_charlist(path), [:exports])

    exports
  end

  defp strip_chunk(beam, chunk_id) do
    {:ok, _module, chunks} = :beam_lib.all_chunks(beam)
    chunks = Enum.reject(chunks, fn {id, _data} -> id == chunk_id end)
    {:ok, binary} = :beam_lib.build_module(chunks)
    binary
  end

  defp replace_chunk(beam, chunk_id, data) do
    {:ok, _module, chunks} = :beam_lib.all_chunks(beam)

    chunks =
      Enum.map(chunks, fn
        {^chunk_id, _old} -> {chunk_id, data}
        other -> other
      end)

    {:ok, binary} = :beam_lib.build_module(chunks)
    binary
  end

  defp create_stale_companion(companion, tools, schemas) do
    quoted =
      quote do
        @moduledoc false
        def __tools__, do: unquote(Macro.escape(tools))
        def __schemas__, do: unquote(Macro.escape(schemas))
        def __generation__, do: 0
      end

    {:module, ^companion, _binary, _term} =
      Module.create(companion, quoted, file: "nofile", line: 1)

    :ok
  end
end
