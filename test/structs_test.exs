defmodule ToolCall.StructsTest do
  use ExUnit.Case, async: true

  alias ToolCall.Structs

  alias ToolCall.TestFixtures.{
    Address,
    Deep,
    NotAStruct,
    NoType,
    NullableAddress,
    OpaqueBox,
    ParamOnly,
    Partial,
    PathNode,
    PrivateField,
    TreeNode,
    WeirdType
  }

  test "struct?/1 recognises compiled structs" do
    assert Structs.struct?(Address)
    refute Structs.struct?(NotAStruct)
  end

  test "enforced_keys/1 recovers @enforce_keys" do
    assert {:ok, [:city]} = Structs.enforced_keys(Address)
    assert {:ok, []} = Structs.enforced_keys(Partial)
  end

  test "fields/1 returns field types with the module's local types expanded" do
    assert {:ok, fields, [], :ok, false} = Structs.fields(Address)
    assert {String, :t, []} = unwrap_remote(fields.city)
    assert {String, :t, []} = unwrap_remote(fields.street)
  end

  test "fields/1 and enforced_keys/1 reject a non-struct" do
    assert :error = Structs.fields(NotAStruct)
    assert :error = Structs.enforced_keys(NotAStruct)
  end

  test "fields/1 returns the module's own cyclic types as instantiations" do
    assert {:ok, fields, [inst], :ok, false} = Structs.fields(PathNode)
    assert inst.key == {:path, 0}
    assert match?({:|, _, [_, nil]}, fields.tail)
  end

  test "fields/1 reports when the struct's own expansion hit the budget" do
    assert {:ok, _fields, [], :truncated, false} = Structs.fields(Deep)
  end

  test "fields/1 falls back to the source file when the typespec chunk is missing" do
    dir = Path.join(System.tmp_dir!(), "tool_call_src_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    file = Path.join(dir, "source_struct.ex")

    module =
      Module.concat([ToolCall.TestFixtures, :"SourceStruct#{System.unique_integer([:positive])}"])

    File.write!(file, """
    defmodule #{inspect(module)} do
      defstruct [:city, :at]
      @type city :: String.t()
      @type t :: %__MODULE__{city: city(), at: Date.t()}
    end
    """)

    Code.compile_file(file)
    on_exit(fn -> File.rm_rf(dir) end)

    assert {:ok, fields, [], :ok, false} = Structs.fields(module)
    assert {String, :t, []} = unwrap_remote(fields.city)
    assert {Date, :t, []} = unwrap_remote(fields.at)
  end

  test "fields/1 expands simple aliases from the source" do
    dir = Path.join(System.tmp_dir!(), "tool_call_alias_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    file = Path.join(dir, "alias_struct.ex")

    module =
      Module.concat([ToolCall.TestFixtures, :"AliasStruct#{System.unique_integer([:positive])}"])

    File.write!(file, """
    defmodule #{inspect(module)} do
      alias ToolCall.TestFixtures.Address
      alias ToolCall.TestFixtures.Address, as: Addr
      defstruct [:a, :b]
      @type t :: %__MODULE__{a: Address.t(), b: Addr.t()}
    end
    """)

    Code.compile_file(file)
    on_exit(fn -> File.rm_rf(dir) end)

    assert {:ok, fields, [], :ok, false} = Structs.fields(module)
    assert {ToolCall.TestFixtures.Address, :t, []} = unwrap_remote(fields.a)
    assert {ToolCall.TestFixtures.Address, :t, []} = unwrap_remote(fields.b)
  end

  test "fields/1 falls back to source for a beam compiled without debug info" do
    dir = Path.join(System.tmp_dir!(), "tool_call_dbg_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    file = Path.join(dir, "no_info_struct.ex")

    module =
      Module.concat([ToolCall.TestFixtures, :"NoInfo#{System.unique_integer([:positive])}"])

    File.write!(file, """
    defmodule #{inspect(module)} do
      @compile {:debug_info, false}
      defstruct [:city]
      @type t :: %__MODULE__{city: String.t()}
    end
    """)

    assert {:ok, _modules, _diagnostics} =
             Kernel.ParallelCompiler.compile_to_path([file], dir, return_diagnostics: true)

    Code.prepend_path(dir)
    assert {:module, ^module} = Code.ensure_loaded(module)
    assert :error = Code.Typespec.fetch_types(module)

    assert {:ok, fields, [], :ok, false} = Structs.fields(module)
    assert {String, :t, []} = unwrap_remote(fields.city)

    on_exit(fn -> File.rm_rf(dir) end)
  end

  test "fields/1 reports a parameterized-only t, a non-literal t/0, and no t at all" do
    assert {:ok, %{a: {:any, _, []}}, [], :parameterized_t, false} = Structs.fields(ParamOnly)
    assert {:ok, %{x: {:any, _, []}}, [], :non_literal_t, false} = Structs.fields(WeirdType)
    assert {:ok, %{x: {:any, _, []}}, [], :ok, false} = Structs.fields(NoType)
  end

  test "fields/1 reports opaque types" do
    assert :opaque = Structs.fields(OpaqueBox)
  end

  test "fields/1 unwraps a struct t that also allows nil" do
    assert {:ok, fields, [], :ok, true} = Structs.fields(NullableAddress)
    assert {String, :t, []} = unwrap_remote(fields.city)
  end

  test "fields/1 lists defstruct fields missing from @type t" do
    assert {:ok, fields, [], :ok, false} = Structs.fields(Partial)
    assert Map.keys(fields) |> Enum.sort() == [:a, :b, :c]
    assert match?({:any, _, []}, fields.b)
  end

  test "fields/1 turns a self-referential t/0 into a struct marker" do
    assert {:ok, fields, [], :ok, false} = Structs.fields(TreeNode)
    assert [marker] = fields.children
    assert match?({:%, _, [TreeNode, {:%{}, _, []}]}, marker)
  end

  test "fields/1 leaves @typep references as local calls" do
    assert {:ok, fields, [], :ok, false} = Structs.fields(PrivateField)
    assert match?({:hidden, _, []}, fields.hidden)
  end

  defp unwrap_remote({{:., _, [module, function]}, _, args}) when is_atom(module),
    do: {module, function, args}

  defp unwrap_remote({:|, _, [value, nil]}), do: unwrap_remote(value)
  defp unwrap_remote(other), do: other
end
