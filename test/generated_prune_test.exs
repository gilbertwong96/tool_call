defmodule ToolCall.GeneratedPruneTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ToolCall.TestModule, only: [compile!: 1]

  alias ToolCall.Generated

  @tag :tmp_dir
  test "prune removes companions whose source file is gone", %{tmp_dir: dir} do
    source = Path.join(dir, "source.ex")
    File.write!(source, "defmodule Source do\nend\n")

    {companion, beam} = write_companion!(dir)
    metadata = beam <> ".source"
    File.write!(metadata, source)

    on_exit(fn -> purge(companion) end)

    assert Generated.prune(dir) == 0
    assert File.exists?(beam)
    assert File.exists?(metadata)

    File.rm!(source)

    assert Generated.prune(dir) == 1
    refute File.exists?(beam)
    refute File.exists?(metadata)
  end

  @tag :tmp_dir
  test "prune leaves foreign companions alone", %{tmp_dir: dir} do
    {companion, beam} = write_companion!(dir, marker: false)
    metadata = beam <> ".source"
    File.write!(metadata, Path.join(dir, "gone.ex"))

    on_exit(fn -> purge(companion) end)

    assert Generated.prune(dir) == 0
    assert File.exists?(beam)
    assert File.exists?(metadata)
  end

  @tag :tmp_dir
  test "prune removes metadata when the companion beam is absent", %{tmp_dir: dir} do
    metadata = Path.join(dir, "Absent.__ToolCall__.beam.source")
    File.write!(metadata, Path.join(dir, "missing.ex"))

    assert Generated.prune(dir) == 0
    refute File.exists?(metadata)
  end

  @tag :tmp_dir
  test "prune ignores metadata it cannot read", %{tmp_dir: dir} do
    metadata = Path.join(dir, "Unreadable.__ToolCall__.beam.source")
    File.mkdir!(metadata)

    assert Generated.prune(dir) == 0
  end

  @tag :tmp_dir
  test "clean removes a legacy companion without a sidecar", %{tmp_dir: dir} do
    {companion, beam} = write_companion!(dir)

    on_exit(fn -> purge(companion) end)

    assert Generated.clean(dir) == 1
    refute File.exists?(beam)
  end

  @tag :tmp_dir
  test "clean removes a companion when its parent beam is missing", %{tmp_dir: dir} do
    source = Path.join(dir, "source.ex")
    File.write!(source, "defmodule Source do\nend\n")

    {companion, beam} = write_companion!(dir)
    metadata = beam <> ".source"
    File.write!(metadata, source)

    on_exit(fn -> purge(companion) end)

    assert Generated.prune(dir) == 0
    assert Generated.clean(dir) == 1
    refute File.exists?(beam)
    refute File.exists?(metadata)
  end

  @tag :tmp_dir
  test "clean removes a legacy companion whose recorded source is gone", %{tmp_dir: dir} do
    source = Path.join(dir, "source.ex")
    File.write!(source, "defmodule Source do\nend\n")

    {companion, beam} = write_companion!(dir, file: source)
    parent = String.trim_trailing(beam, ".__ToolCall__.beam") <> ".beam"
    File.write!(parent, "parent")

    on_exit(fn -> purge(companion) end)

    assert Generated.clean(dir) == 0

    File.rm!(source)

    assert Generated.clean(dir) == 1
    refute File.exists?(beam)
  end

  @tag :tmp_dir
  test "clean keeps an unreadable legacy companion when its parent beam exists", %{tmp_dir: dir} do
    beam = Path.join(dir, "Corrupt.__ToolCall__.beam")
    File.write!(beam, "not a beam")
    File.write!(String.trim_trailing(beam, ".__ToolCall__.beam") <> ".beam", "parent")

    assert Generated.clean(dir) == 0
    assert File.exists?(beam)
  end

  @tag :tmp_dir
  test "clean prefers a live compile_info source over a stale sidecar", %{tmp_dir: dir} do
    source = Path.join(dir, "source.ex")
    File.write!(source, "defmodule Source do\nend\n")

    {companion, beam} = write_companion!(dir, file: source)
    File.write!(beam <> ".source", Path.join(dir, "stale-source.ex"))
    File.write!(String.trim_trailing(beam, ".__ToolCall__.beam") <> ".beam", "parent")

    on_exit(fn -> purge(companion) end)

    assert Generated.clean(dir) == 0
    assert File.exists?(beam)
  end

  @tag :tmp_dir
  test "clean keeps a companion when its parent beam exists", %{tmp_dir: dir} do
    source = Path.join(dir, "source.ex")
    File.write!(source, "defmodule Source do\nend\n")

    {companion, beam} = write_companion!(dir)
    metadata = beam <> ".source"
    File.write!(metadata, source)
    File.write!(String.trim_trailing(beam, ".__ToolCall__.beam") <> ".beam", "parent")

    on_exit(fn -> purge(companion) end)

    assert Generated.clean(dir) == 0
    assert File.exists?(beam)
    assert File.exists?(metadata)
  end

  test "prune returns zero without a Mix project" do
    project = Mix.Project.pop()

    on_exit(fn ->
      :ok = Mix.Project.push(project.name, project[:file], project[:app])
    end)

    assert Generated.prune() == 0
    assert Generated.clean() == 0
  end

  test "a ToolCall compile prunes orphan companions" do
    {companion, beam} = write_companion!(Mix.Project.compile_path())
    metadata = beam <> ".source"
    File.write!(metadata, Path.join(System.tmp_dir!(), "missing_tool_call_source.ex"))

    on_exit(fn ->
      purge(companion)
      File.rm(beam)
      File.rm(metadata)
    end)

    assert File.exists?(beam)

    compile!("""
    defmodule FIXTURE do
      use ToolCall

      @spec go(x :: integer()) :: integer()
      def go(x), do: x
    end
    """)

    refute File.exists?(beam)
    refute File.exists?(metadata)
  end

  test "mix tool_call.clean removes orphan companions" do
    {companion, beam} = write_companion!(Mix.Project.compile_path())
    metadata = beam <> ".source"
    File.write!(metadata, Path.join(System.tmp_dir!(), "missing_tool_call_source.ex"))

    on_exit(fn ->
      purge(companion)
      File.rm(beam)
      File.rm(metadata)
    end)

    Mix.Task.reenable("tool_call.clean")
    output = capture_io(fn -> Mix.Task.run("tool_call.clean") end)

    assert output =~ "Removed"
    refute File.exists?(beam)
    refute File.exists?(metadata)

    Mix.Task.reenable("tool_call.clean")
    output = capture_io(fn -> Mix.Task.run("tool_call.clean") end)
    assert output =~ "No stale ToolCall companions found"
  end

  defp write_companion!(dir, opts \\ []) do
    companion =
      String.to_atom(
        "Elixir.ToolCall.GeneratedPruneTest.Companion#{System.unique_integer([:positive])}.__ToolCall__"
      )

    marker? = Keyword.get(opts, :marker, true)
    file = Keyword.get(opts, :file, "nofile")

    quoted =
      if marker? do
        quote do
          @moduledoc false
          def __tool_call_companion__, do: true
          def __tools__, do: []
          def __schemas__, do: %{}
          def __generation__, do: 1
        end
      else
        quote do
          @moduledoc false
          def __tools__, do: []
          def __schemas__, do: %{}
          def __generation__, do: 1
        end
      end

    {:module, ^companion, binary, _term} =
      Module.create(companion, quoted, file: file, line: 1)

    beam = Path.join(dir, Atom.to_string(companion) <> ".beam")
    File.write!(beam, binary)
    {companion, beam}
  end

  defp purge(module) do
    :code.purge(module)
    :code.delete(module)
    :ok
  end
end
