defmodule ToolCall.TypedocTest do
  # Bytecode fixture tests toggle the global compiler `docs` option, so this
  # module must not run concurrently with other tests.
  use ExUnit.Case, async: false

  alias ToolCall.IR.{Param, Tool}
  alias ToolCall.Typedoc

  test "from_docs/1 extracts visible type docs and ignores other entries" do
    docs =
      {:docs_v1, 0, :elixir, "text/markdown", :none, %{},
       [
         {{:type, :address, 0}, 0, [], %{"en" => "Postal address"}, %{}},
         {{:type, :opaque_t, 0}, 0, [], %{"en" => "Opaque"}, %{opaque: true}},
         {{:type, :hidden_t, 0}, 0, [], :hidden, %{}},
         {{:function, :go, 1}, 0, [], %{"en" => "Function"}, %{}}
       ]}

    assert Typedoc.from_docs(docs) == %{
             {:address, 0} => "Postal address",
             {:opaque_t, 0} => "Opaque"
           }
  end

  test "from_docs/1 prefers English and falls back to another language" do
    docs =
      {:docs_v1, 0, :elixir, "text/markdown", :none, %{},
       [
         {{:type, :address, 0}, 0, [], %{"fr" => "Adresse", "en" => "Address"}, %{}},
         {{:type, :only_fr, 0}, 0, [], %{"fr" => "Adresse seulement"}, %{}},
         {{:type, :mixed, 0}, 0, [], %{"en" => :hidden, "fr" => "Adresse mixte"}, %{}},
         {{:type, :binary_doc, 0}, 0, [], "Raw doc", %{}}
       ]}

    assert Typedoc.from_docs(docs) == %{
             {:address, 0} => "Address",
             {:only_fr, 0} => "Adresse seulement",
             {:mixed, 0} => "Adresse mixte",
             {:binary_doc, 0} => "Raw doc"
           }
  end

  test "from_docs/1 ignores malformed entries and terms" do
    docs =
      {:docs_v1, 0, :elixir, "text/markdown", :none, %{},
       [
         {{:type, "name", 0}, 0, [], "Bad name", %{}},
         {{:type, :negative, -1}, 0, [], "Bad arity", %{}},
         {{:type, :no_doc, 0}, 0, [], %{}, %{}},
         :junk
       ]}

    assert Typedoc.from_docs(docs) == %{}
    assert Typedoc.from_docs(:not_docs) == %{}
  end

  test "from_bytecode/1 reads typedoc text from the Docs chunk" do
    module = "TypedocBytecodeFixture#{System.unique_integer([:positive])}"

    [{_module, bytecode}] =
      compile_fixture(
        """
        defmodule #{module} do
          @typedoc "Postal address"
          @type address :: String.t()
        end
        """,
        docs: true
      )

    assert Typedoc.from_bytecode(bytecode) == %{{:address, 0} => "Postal address"}
  end

  test "from_bytecode/1 returns an empty map when the Docs chunk is absent" do
    module = "TypedocNoDocsFixture#{System.unique_integer([:positive])}"

    [{_module, bytecode}] =
      compile_fixture(
        """
        defmodule #{module} do
          @typedoc "Postal address"
          @type address :: String.t()
        end
        """,
        docs: false
      )

    assert Typedoc.from_bytecode(bytecode) == %{}
  end

  test "from_bytecode/1 returns an empty map when the beam is unreadable" do
    assert Typedoc.from_bytecode(:erlang.term_to_binary(:not_a_beam)) == %{}
  end

  test "from_bytecode/1 returns an empty map when the Docs chunk is corrupt" do
    module = "TypedocCorruptFixture#{System.unique_integer([:positive])}"

    [{_module, bytecode}] =
      compile_fixture(
        """
        defmodule #{module} do
          @typedoc "Postal address"
          @type address :: String.t()
        end
        """,
        docs: true
      )

    assert Typedoc.from_bytecode(corrupt_docs_chunk(bytecode)) == %{}
  end

  test "from_bytecode/1 reports a decodable but structurally invalid Docs chunk as corrupt" do
    module = "TypedocStructureFixture#{System.unique_integer([:positive])}"

    [{_module, bytecode}] =
      compile_fixture(
        """
        defmodule #{module} do
          @typedoc "Postal address"
          @type address :: String.t()
        end
        """,
        docs: true
      )

    invalid = {:docs_v1, 0, :elixir, "text/markdown", :none, %{}, :not_a_list}

    assert Typedoc.from_bytecode(replace_docs_chunk(bytecode, invalid)) == %{}

    assert Typedoc.from_bytecode_result(replace_docs_chunk(bytecode, invalid)) ==
             {:error, :corrupt_docs_chunk}
  end

  test "from_bytecode_result/1 distinguishes missing and corrupt Docs chunks" do
    module = "TypedocStatusFixture#{System.unique_integer([:positive])}"
    no_docs_module = "TypedocStatusNoDocsFixture#{System.unique_integer([:positive])}"

    [{_module, bytecode}] =
      compile_fixture(
        """
        defmodule #{module} do
          @typedoc "Postal address"
          @type address :: String.t()
        end
        """,
        docs: true
      )

    [{_module, no_docs_bytecode}] =
      compile_fixture(
        """
        defmodule #{no_docs_module} do
          @typedoc "Postal address"
          @type address :: String.t()
        end
        """,
        docs: false
      )

    assert Typedoc.from_bytecode_result(bytecode) ==
             {:ok, %{{:address, 0} => "Postal address"}}

    assert Typedoc.from_bytecode_result(no_docs_bytecode) == {:error, :missing_docs_chunk}

    assert Typedoc.from_bytecode_result(corrupt_docs_chunk(bytecode)) ==
             {:error, :corrupt_docs_chunk}

    assert Typedoc.from_bytecode_result(:erlang.term_to_binary(:not_a_beam)) ==
             {:error, :unreadable_beam}
  end

  test "key/2 returns the local type key for a direct reference" do
    assert Typedoc.key({:address, [], []}, definitions()) == {:address, 0}
    assert Typedoc.key({:pair, [], [{:integer, [], []}]}, definitions()) == {:pair, 1}
  end

  test "key/2 unwraps a nullable local type on either side" do
    address_ast = {:address, [], []}

    assert Typedoc.key({:|, [], [address_ast, nil]}, definitions()) == {:address, 0}
    assert Typedoc.key({:|, [], [nil, address_ast]}, definitions()) == {:address, 0}
  end

  test "key/2 does not unwrap a list, an arbitrary union, a remote type or an unknown type" do
    address_ast = {:address, [], []}
    remote_ast = {{:., [], [{:__aliases, [], [:URI]}, :t]}, [], []}

    assert Typedoc.key({:list, [], [address_ast]}, definitions()) == nil
    assert Typedoc.key({:|, [], [address_ast, {:integer, [], []}]}, definitions()) == nil
    assert Typedoc.key(remote_ast, definitions()) == nil
    assert Typedoc.key({:missing, [], []}, definitions()) == nil
  end

  test "apply/3 fills only nil descriptions with typedoc text" do
    tool = %Tool{
      name: "create",
      params: [
        %Param{name: "address"},
        %Param{name: "note", description: "doc wins"},
        %Param{name: "untyped"}
      ]
    }

    keys = %{
      {"create", "address"} => {:address, 0},
      {"create", "note"} => {:address, 0}
    }

    docs = %{{:address, 0} => "Postal address"}

    assert [%Tool{params: [address, note, untyped]}] = Typedoc.apply([tool], keys, docs)
    assert address.description == "Postal address"
    assert note.description == "doc wins"
    assert untyped.description == nil
  end

  test "apply/3 preserves an explicit empty-string description" do
    tool = %Tool{name: "create", params: [%Param{name: "address", description: ""}]}
    keys = %{{"create", "address"} => {:address, 0}}
    docs = %{{:address, 0} => "Postal address"}

    assert [%Tool{params: [%Param{description: ""}]}] = Typedoc.apply([tool], keys, docs)
  end

  test "apply/3 leaves tools unchanged when there is no text or no key" do
    tool = %Tool{name: "create", params: [%Param{name: "address"}]}
    keys = %{{"create", "address"} => {:address, 0}}
    docs = %{{:address, 0} => "Postal address"}

    assert Typedoc.apply([tool], keys, %{{:address, 0} => ""}) == [tool]
    assert Typedoc.apply([tool], keys, %{}) == [tool]
    assert Typedoc.apply([tool], %{}, docs) == [tool]
  end

  # `mix test` disables docs chunks by default; set the global option
  # explicitly for each fixture and restore it afterwards.
  defp compile_fixture(source, docs: enabled?) do
    previous = Code.compiler_options()[:docs]
    Code.compiler_options(docs: enabled?)

    try do
      Code.compile_string(source)
    after
      Code.compiler_options(docs: previous)
    end
  end

  # Replace the first byte of the Docs chunk payload with an invalid external
  # term marker; `:beam_lib.chunks/2` still returns the chunk, but decoding it
  # raises.
  defp corrupt_docs_chunk(beam) do
    {offset, 4} = beam |> :binary.matches("Docs") |> List.last()
    size = byte_size(beam)

    <<binary_part(beam, 0, offset + 8)::binary, 0,
      binary_part(beam, offset + 9, size - offset - 9)::binary>>
  end

  defp replace_docs_chunk(beam, docs) do
    {:ok, _module, chunks} = :beam_lib.all_chunks(beam)

    chunks =
      Enum.map(chunks, fn
        {~c"Docs", _data} -> {~c"Docs", :erlang.term_to_binary(docs)}
        other -> other
      end)

    {:ok, binary} = :beam_lib.build_module(chunks)
    binary
  end

  defp definitions do
    %{
      {:address, 0} => {[], {:string, [], []}},
      {:pair, 1} => {[{:a, [], nil}], {:tuple, [], []}}
    }
  end
end
