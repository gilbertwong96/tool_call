defmodule ToolCall.TypeSourceTest.Capture do
  @moduledoc false

  defmacro __before_compile__(env) do
    {name, arity} = Module.get_attribute(env.module, :type_source_fetch) || {:go, 2}
    state = ToolCall.TypeSource.Typespec.load(env.module, env)
    result = ToolCall.TypeSource.Typespec.fetch(state, name, arity)

    quote do
      @doc false
      def __type_source_result__, do: unquote(Macro.escape(result))
    end
  end
end

defmodule ToolCall.TypeSourceTest do
  use ExUnit.Case, async: true

  import ToolCall.TestModule

  alias ToolCall.Diagnostic
  alias ToolCall.TypeSource.{Declaration, Param}
  alias ToolCall.TypeSource.Typespec

  defp declaration(source) do
    module = compile!(source)

    case module.__type_source_result__() do
      {:ok, %Declaration{} = declaration} -> declaration
      other -> flunk("expected a declaration, got: #{inspect(other)}")
    end
  end

  defp fetch_error(source) do
    module = compile!(source)

    case module.__type_source_result__() do
      {:error, messages} -> messages
      other -> flunk("expected an error, got: #{inspect(other)}")
    end
  end

  defp diagnostic?(diagnostics, text) do
    Enum.any?(diagnostics, fn
      %Diagnostic{message: message} -> String.contains?(message, text)
      _other -> false
    end)
  end

  test "named parameters keep their spec names and types" do
    declaration =
      declaration("""
      defmodule FIXTURE do
        @type_source_fetch {:go, 2}
        @spec go(city :: String.t(), days :: pos_integer()) :: :ok
        def go(_city, _days), do: :ok
        @before_compile ToolCall.TypeSourceTest.Capture
      end
      """)

    assert declaration.name == :go
    assert declaration.arity == 2
    assert declaration.return == :ok
    assert declaration.bindings == %{}
    assert declaration.indirect? == false
    assert declaration.source_label == "the @spec"
    assert declaration.warnings == []

    assert [%Param{name: :city, named?: true}, %Param{name: :days, named?: true}] =
             declaration.params

    assert declaration.source |> elem(0) == :"::"
  end

  test "unnamed and underscore parameters stay unnamed" do
    declaration =
      declaration("""
      defmodule FIXTURE do
        @type_source_fetch {:go, 2}
        @spec go(String.t(), _days :: integer()) :: :ok
        def go(_city, _days), do: :ok
        @before_compile ToolCall.TypeSourceTest.Capture
      end
      """)

    assert [%Param{name: nil, named?: false}, %Param{name: nil, named?: false}] =
             declaration.params
  end

  test "when constraints become bindings" do
    declaration =
      declaration("""
      defmodule FIXTURE do
        @type_source_fetch {:go, 1}
        @spec go(x) :: x when x: integer()
        def go(x), do: x
        @before_compile ToolCall.TypeSourceTest.Capture
      end
      """)

    assert declaration.bindings |> Map.fetch!(:x) |> Macro.to_string() == "integer()"
    assert [%Param{name: nil, named?: false, type: {:x, _, _}}] = declaration.params
  end

  test "overloads keep the first declared spec and warn" do
    declaration =
      declaration("""
      defmodule FIXTURE do
        @type_source_fetch {:go, 1}
        @spec go(integer()) :: :ok
        @spec go(String.t()) :: :error
        def go(_value), do: :ok
        @before_compile ToolCall.TypeSourceTest.Capture
      end
      """)

    assert declaration.return == :ok

    assert [%Diagnostic{} | _] = declaration.warnings
    assert diagnostic?(declaration.warnings, "has 2 @spec clauses")
  end

  test "a missing spec reports the function" do
    messages =
      fetch_error("""
      defmodule FIXTURE do
        @type_source_fetch {:go, 2}
        @spec other(integer()) :: :ok
        def other(value), do: value
        @before_compile ToolCall.TypeSourceTest.Capture
      end
      """)

    assert [%Diagnostic{} | _] = messages
    assert diagnostic?(messages, "has no @spec")
  end

  test "a reduced arity reports the existing arity" do
    messages =
      fetch_error("""
      defmodule FIXTURE do
        @type_source_fetch {:go, 2}
        @spec go(integer()) :: :ok
        def go(value, _extra \\\\ 1), do: value
        @before_compile ToolCall.TypeSourceTest.Capture
      end
      """)

    assert [%Diagnostic{} | _] = messages
    assert diagnostic?(messages, "found go/1 instead")
  end

  test "exact no_return is indirect" do
    declaration =
      declaration("""
      defmodule FIXTURE do
        @type_source_fetch {:go, 1}
        @spec go(x :: integer()) :: no_return()
        def go(x), do: raise(x)
        @before_compile ToolCall.TypeSourceTest.Capture
      end
      """)

    assert declaration.indirect?
  end

  test "none and aliased no_return are not indirect" do
    none =
      declaration("""
      defmodule FIXTURE do
        @type_source_fetch {:go, 1}
        @spec go(x :: integer()) :: none()
        def go(x), do: x
        @before_compile ToolCall.TypeSourceTest.Capture
      end
      """)

    aliased =
      declaration("""
      defmodule FIXTURE do
        @type_source_fetch {:go, 1}
        @type nope :: no_return()
        @spec go(x :: integer()) :: nope()
        def go(x), do: x
        @before_compile ToolCall.TypeSourceTest.Capture
      end
      """)

    refute none.indirect?
    refute aliased.indirect?
  end

  test "spec_signature handles wrapped and bare specs" do
    spec = {:when, [], [{:"::", [], [{:go, [], []}, :ok]}, [x: {:integer, [], []}]]}

    assert Typespec.spec_signature(spec) == {:go, 0}
    assert Typespec.spec_signature({:"::", [], [{:go, [], []}, :ok]}) == {:go, 0}
    assert Typespec.spec_signature({:not_a_spec, [], []}) == nil
  end

  test "TypeAst substitutes variable nodes recursively" do
    assert ToolCall.TypeAst.substitute_vars({:x, [], nil}, %{x: {:integer, [], []}}) ==
             {:integer, [], []}

    assert ToolCall.TypeAst.substitute_vars({:list, [], [{:x, [], nil}]}, %{
             x: {:integer, [], []}
           }) == {:list, [], [{:integer, [], []}]}
  end

  test "constraint_bindings resolves forward and reverse references" do
    constraints = [x: {:list, [], [{:t, [], nil}]}, t: {:integer, [], []}]

    assert Typespec.constraint_bindings(constraints) == %{
             x: {:list, [], [{:integer, [], []}]},
             t: {:integer, [], []}
           }

    assert Typespec.constraint_bindings([{:x, {:integer, [], []}}, :bad]) == %{
             x: {:integer, [], []}
           }
  end
end
