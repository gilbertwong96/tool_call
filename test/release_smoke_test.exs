defmodule ToolCall.ReleaseSmokeTest do
  # `mix release` strips the Docs and Dbgi chunks before shipping the beams.
  # This smoke test reproduces that part of a release: it compiles a real
  # source file through the Mix project, strips the same chunks from the module
  # and its typedoc companion, loads both from an isolated code path, and
  # exercises the public API. It does not assemble an OTP release; see the
  # release notes in README.md for the manual `mix release` check and its
  # remaining limits.
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias ToolCall.Generated

  @source """
  defmodule FIXTURE do
    use ToolCall

    @typedoc "Postal address"
    @type address :: String.t()

    @doc "Send a parcel."
    @spec send(to :: address()) :: :ok
    def send(_to), do: :ok
  end
  """

  test "stripped release-style beams keep typedoc descriptions and dispatch" do
    module = unique_module("Release")
    path = write_source(module, @source)
    companion = Generated.companion(module)
    companion_beam = companion_beam(module)

    release_dir =
      Path.join(System.tmp_dir!(), "tool_call_release_#{System.unique_integer([:positive])}")

    on_exit(fn ->
      :code.del_path(String.to_charlist(release_dir))
      purge(companion)
      purge(module)
      File.rm(companion_beam)
      File.rm(path)
      File.rm_rf(release_dir)
    end)

    {^module, main_beam, _diagnostics} = compile!(path)
    assert File.exists?(companion_beam)

    File.mkdir_p!(release_dir)
    write_stripped_beam!(release_dir, module, main_beam)
    write_stripped_beam!(release_dir, companion, File.read!(companion_beam))

    purge(companion)
    purge(module)
    File.rm!(companion_beam)
    :code.add_patha(String.to_charlist(release_dir))

    assert Code.ensure_loaded?(module)
    assert :code.which(module) == String.to_charlist(beam_path(release_dir, module))

    assert Code.fetch_docs(module) == {:error, :chunk_not_found}
    assert Code.Typespec.fetch_specs(module) == :error
    assert Code.ensure_loaded?(companion)
    assert :code.which(companion) == String.to_charlist(beam_path(release_dir, companion))

    assert [%{"function" => %{"parameters" => %{"properties" => %{"to" => to}}}}] =
             ToolCall.emit(module, :openai)

    assert to["description"] == "Postal address"
    assert ToolCall.run(module, :send, %{"to" => "Oslo"}) == {:ok, :ok}
  end

  test "a failed companion refresh falls back to phase-one data, not the old companion" do
    module = unique_module("StaleWrite")
    path = write_source(module, @source)
    companion = Generated.companion(module)
    beam = companion_beam(module)

    on_exit(fn ->
      File.rm_rf(beam)
      purge(companion)
      purge(module)
      File.rm(path)
    end)

    {^module, _main_beam, _diagnostics} = compile!(path)
    assert param_description(module, "send", "to") == "Postal address"

    # Make the atomic write fail after the old companion has been purged.
    File.rm!(beam)
    File.mkdir_p!(beam)

    File.write!(
      path,
      @source
      |> String.replace("FIXTURE", inspect(module))
      |> String.replace("Postal address", "Updated address")
    )

    {^module, _main_beam, diagnostics} = compile!(path)
    warning = Enum.map_join(diagnostics, "\n", & &1.message)

    assert warning =~ "could not write the typedoc companion beam"
    assert param_description(module, "send", "to") == nil
    assert ToolCall.emit(module, :openai) |> hd() |> schema_param_description("to") == nil
  end

  defp unique_module(label) do
    Module.concat([__MODULE__, "#{label}#{System.unique_integer([:positive])}"])
  end

  defp write_source(module, source) do
    path = Path.join(System.tmp_dir!(), "#{inspect(module)}.ex")
    File.write!(path, String.replace(source, "FIXTURE", inspect(module)))
    path
  end

  defp compile!(path) do
    previous = Code.compiler_options()[:docs]
    Code.compiler_options(docs: true)

    try do
      {[{module, binary} | _], diagnostics} =
        Code.with_diagnostics(fn -> Code.compile_file(path) end)

      {module, binary, diagnostics}
    after
      Code.compiler_options(docs: previous)
    end
  end

  defp param_description(module, tool_name, param_name) do
    tool = Enum.find(ToolCall.tools(module), &(&1.name == tool_name))
    param = Enum.find(tool.params, &(&1.name == param_name))
    param.description
  end

  defp schema_param_description(schema, param_name) do
    get_in(schema, ["function", "parameters", "properties", param_name, "description"])
  end

  defp companion_beam(module),
    do: beam_path(Mix.Project.compile_path(), Generated.companion(module))

  defp beam_path(dir, module), do: Path.join(dir, Atom.to_string(module) <> ".beam")

  defp write_stripped_beam!(dir, module, beam) do
    File.write!(beam_path(dir, module), strip_release_chunks(beam))
  end

  defp strip_release_chunks(beam) do
    {:ok, _module, chunks} = :beam_lib.all_chunks(beam)
    chunks = Enum.reject(chunks, fn {id, _data} -> id in [~c"Docs", ~c"Dbgi"] end)
    {:ok, binary} = :beam_lib.build_module(chunks)
    binary
  end

  defp purge(module) do
    :code.purge(module)
    :code.delete(module)
    :ok
  end
end
