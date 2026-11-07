defmodule ToolCall.BuilderNilDescription do
  use ToolCall

  @doc """
  Go.

  ## Parameters
    * `x` - documented
  """
  @tool_param %{fun: :go, name: "x", description: nil}
  @spec go(x :: integer()) :: integer()
  def go(x), do: x
end

defmodule ToolCall.BuilderTest.Capture do
  @moduledoc false
  # Exposes the Builder result from inside a fixture's compilation without
  # adding it to ToolCall's public API.

  defmacro __before_compile__(env) do
    module = env.module

    result =
      ToolCall.Builder.build(
        module,
        module |> Module.get_attribute(:tool_call_defs) |> List.wrap(),
        module |> Module.get_attribute(:spec) |> List.wrap(),
        module |> Module.get_attribute(:tool_param) |> List.wrap(),
        env,
        Module.get_attribute(module, :tool_call_type_providers) || []
      )

    quote do
      @doc false
      def __build_result__, do: unquote(Macro.escape(result))
    end
  end
end

defmodule ToolCall.BuilderTest do
  use ExUnit.Case, async: true

  import ToolCall.TestModule

  test "omits defaults that are not compile-time literals" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Non-literal default."
        @spec stamp(at :: DateTime.t() | nil) :: String.t()
        def stamp(at \\\\ DateTime.utc_now()), do: inspect(at)
      end
      """)

    refute Map.has_key?(param_schema(module, "stamp", "at"), "default")
    assert {:ok, _value} = ToolCall.run(module, :stamp, %{})
  end

  test "renames duplicate parameter names instead of shipping an uncallable tool" do
    {module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall

        @spec go(city :: String.t(), city :: integer()) :: list()
        def go(city, count), do: [city, count]
      end
      """)

    assert warnings =~ "used twice"

    schema = ToolCall.emit(module, :openai) |> hd() |> get_in(["function", "parameters"])
    assert Map.keys(schema["properties"]) |> Enum.sort() == ["city", "city_2"]
    assert schema["required"] == ["city", "city_2"]

    assert {:ok, ["x", 2]} =
             ToolCall.run(module, :go, %{"city" => "x", "city_2" => 2})
  end

  test "applies @tool_param to a renamed duplicate parameter" do
    {module, _warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall

        @tool_param %{fun: :go, name: "city_2", description: "second city only"}
        @spec go(city :: String.t(), city :: integer()) :: String.t()
        def go(city, count), do: city <> Integer.to_string(count)
      end
      """)

    assert param_schema(module, "go", "city")["description"] == nil
    assert param_schema(module, "go", "city_2")["description"] == "second city only"
  end

  test "applies @doc parameter bullets to a renamed duplicate parameter" do
    {module, _warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Duplicate names.\n\n## Parameters\n  * `city_2` - second city only"
        @spec go(city :: String.t(), city :: integer()) :: String.t()
        def go(city, count), do: city <> Integer.to_string(count)
      end
      """)

    assert param_schema(module, "go", "city")["description"] == nil
    assert param_schema(module, "go", "city_2")["description"] == "second city only"
  end

  test "uses doc bullets to name unannotated spec parameters" do
    {module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall

        @doc \"\"\"
        Search.

        ## Parameters
          * `city` - city name
          * `days` - forecast days
        \"\"\"
        @spec go(String.t(), integer()) :: :ok
        def go(city, days), do: {city, days}
      end
      """)

    refute warnings =~ "has no name"

    schema = ToolCall.emit(module, :openai) |> hd() |> get_in(["function", "parameters"])
    assert schema["properties"]["city"]["description"] == "city name"
    assert schema["properties"]["days"]["description"] == "forecast days"

    assert {:ok, {"Oslo", 2}} =
             ToolCall.run(module, :go, %{"city" => "Oslo", "days" => 2})
  end

  test "unnamed parameters fall back to positional names" do
    {module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall

        @spec go(_ :: String.t(), _ :: integer()) :: list()
        def go(_, _), do: []
      end
      """)

    assert warnings =~ "has no name in the @spec"

    schema = ToolCall.emit(module, :openai) |> hd() |> get_in(["function", "parameters"])
    assert Map.keys(schema["properties"]) |> Enum.sort() == ["arg1", "arg2"]

    assert {:ok, []} = ToolCall.run(module, :go, %{"arg1" => "x", "arg2" => 1})
  end

  test "drops defaults that JSON cannot carry" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @spec go(pair :: list(), at :: {integer(), integer()}) :: term()
        def go(pair \\\\ {1, 2}, at \\\\ {3, 4}), do: {pair, at}
      end
      """)

    refute Map.has_key?(param_schema(module, "go", "pair"), "default")

    assert Enum.all?(ToolCall.emit(module, :openai), &json_safe?/1),
           "the schema must be JSON-encodable, defaults included"
  end

  test "warns when strict mode would close an open object" do
    {module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall

        @spec go(o :: keyword(String.t()), t :: %{String.t() => integer()}) :: map()
        def go(o, t), do: Map.merge(o, t)
      end
      """)

    assert warnings =~ ~s(parameter "o" of go/2 has an open object)
    assert warnings =~ ~s(parameter "t" of go/2 has an open object)

    strict =
      ToolCall.emit(module, :openai, strict: true)
      |> hd()
      |> get_in(["function", "parameters", "properties"])

    assert %{"o" => %{"additionalProperties" => false}} = strict
  end

  test "warns once about map(), which strict mode cannot express" do
    {_module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall

        @spec go(m :: map()) :: map()
        def go(m), do: m
      end
      """)

    assert warnings =~ "has an open object"
    refute warnings =~ "has no JSON type"
  end

  test "warns that strict mode cannot express tuple positions" do
    {_module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall

        @spec go(point :: {float(), float()}) :: atom()
        def go(_point), do: :ok
      end
      """)

    assert warnings =~ "prefixItems"
  end

  test "warns about tool names the providers reject" do
    {_module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall

        @spec find?(q :: String.t()) :: boolean()
        def find?(q), do: q != ""
      end
      """)

    assert warnings =~ "not accepted by OpenAI or Anthropic"
  end

  test "keeps only the first tool when two arities share a name" do
    {module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall

        @spec go(a :: String.t()) :: String.t()
        def go(a), do: a

        @spec go(a :: String.t(), b :: integer()) :: String.t()
        def go(a, b), do: a <> Integer.to_string(b)
      end
      """)

    assert warnings =~ "defined more than once"
    assert ToolCall.tool_names(module) == ["go"]
    assert {:ok, "x"} = ToolCall.run(module, :go, %{"a" => "x"})
  end

  test "points tool-level warnings at the definition line" do
    source = """
    defmodule FIXTURE do
      use ToolCall

      @spec go(a :: String.t()) :: String.t()
      def go(a), do: a

      @spec go(a :: String.t(), b :: integer()) :: String.t()
      def go(a, b), do: a <> Integer.to_string(b)
    end
    """

    {_module, diagnostics} = compile_with_diagnostics!(source)

    duplicate = Enum.find(diagnostics, &(&1.message =~ "defined more than once"))

    expected =
      source |> String.split("\n") |> Enum.find_index(&(&1 =~ "def go(a, b)")) |> Kernel.+(1)

    assert duplicate.position == expected
  end

  test "warns about an unknown wire format" do
    {module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall

        @tool_param %{fun: :go, name: :amount, wire: :string_intger}
        @spec go(amount :: integer()) :: integer()
        def go(amount), do: amount
      end
      """)

    assert warnings =~ "unknown wire format"
    assert param_schema(module, "go", "amount") == %{"type" => "integer"}
  end

  test "warns about unknown @tool_param keys" do
    {module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Typo."
        @tool_param %{fun: :go, name: "x", descrption: "typo"}
        @spec go(x :: integer()) :: integer()
        def go(x), do: x
      end
      """)

    assert warnings =~ "unknown key(s) [:descrption]"
    refute Map.has_key?(param_schema(module, "go", "x"), "description")
  end

  test "warns and keeps the doc description when @tool_param description is not a string" do
    {module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Go."
        @tool_param %{fun: :go, name: "x", description: 42}
        @spec go(x :: integer()) :: integer()
        def go(x), do: x
      end
      """)

    assert warnings =~ "must be a string"
    refute Map.has_key?(param_schema(module, "go", "x"), "description")
  end

  test "warns about duplicate @tool_param entries" do
    {module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Dupe."
        @tool_param %{fun: :go, name: "x", description: "first"}
        @tool_param %{fun: :go, name: "x", description: "second"}
        @spec go(x :: integer()) :: integer()
        def go(x), do: x
      end
      """)

    assert warnings =~ "duplicate @tool_param"
    assert param_schema(module, "go", "x")["description"] in ["first", "second"]
  end

  test "ignores wire: :string_integer on parameters that are not integer()" do
    {module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Float."
        @tool_param %{fun: :f, name: "x", wire: :string_integer}
        @spec f(x :: float()) :: float()
        def f(x), do: x

        @doc "Array."
        @tool_param %{fun: :g, name: "xs", wire: :string_integer}
        @spec g(xs :: [integer()]) :: [integer()]
        def g(xs), do: xs
      end
      """)

    assert warnings =~ ~s(ignoring it for "x")
    assert warnings =~ ~s(ignoring it for "xs")
    assert param_schema(module, "f", "x") == %{"type" => "number"}

    assert param_schema(module, "g", "xs") == %{
             "type" => "array",
             "items" => %{"type" => "integer"}
           }

    assert ToolCall.run(module, :g, %{"xs" => [1.0]}) == {:ok, [1]}
  end

  test "rejects use options it does not implement" do
    assert_raise ArgumentError, ~r/accepts only :types/, fn ->
      compile!("""
      defmodule FIXTURE do
        use ToolCall, emit: [:openai]
      end
      """)
    end
  end

  defp build_fixture!(body) do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall
        @before_compile ToolCall.BuilderTest.Capture

      #{body}
      end
      """)

    module.__build_result__()
  end

  defp strip_meta(ast) do
    Macro.prewalk(ast, fn
      {name, _meta, args} -> {name, [], args}
      other -> other
    end)
  end

  defp json_safe?(term) when is_map(term) do
    Enum.all?(term, fn {key, value} ->
      (is_binary(key) or is_atom(key)) and json_safe?(value)
    end)
  end

  defp json_safe?(term) when is_list(term), do: Enum.all?(term, &json_safe?/1)

  defp json_safe?(term)
       when is_number(term) or is_binary(term) or is_boolean(term) or is_nil(term),
       do: true

  defp json_safe?(_term), do: false

  test "keeps literal defaults" do
    {module, _warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Literal defaults."
        @spec go(
                n :: integer(),
                s :: String.t(),
                a :: atom(),
                b :: boolean(),
                l :: list(integer()),
                m :: map()
              ) :: :ok
        def go(n \\\\ 3, s \\\\ "x", a \\\\ :ok, b \\\\ true, l \\\\ [1, 2], m \\\\ %{a: 1}), do: {n, s, a, b, l, m}
      end
      """)

    assert param_schema(module, "go", "n")["default"] == 3
    assert param_schema(module, "go", "s")["default"] == "x"
    assert param_schema(module, "go", "a")["default"] == "ok"
    assert param_schema(module, "go", "b")["default"] == true
    assert param_schema(module, "go", "l")["default"] == [1, 2]
    assert param_schema(module, "go", "m")["default"] == %{a: 1}
  end

  test "keeps sigil defaults and sends a charlist as a string" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Sigils."
        @spec go(
                s :: String.t(),
                c :: charlist(),
                w :: list(String.t()),
                at :: Date.t() | nil
              ) :: :ok
        def go(s \\\\ ~s"hi", c \\\\ ~c"ab", w \\\\ ~w(a b), at \\\\ ~D[2024-01-01]), do: {s, c, w, at}

        @doc "Upper sigils."
        @spec upper(s :: String.t(), c :: charlist(), w :: list(String.t())) :: :ok
        def upper(s \\\\ ~S"HI", c \\\\ ~C"CD", w \\\\ ~W(C D)), do: {s, c, w}

        @doc "Interpolated sigil."
        @spec interp(s :: String.t()) :: String.t()
        def interp(s \\\\ ~s"a\#{1}"), do: s

        @doc "List charlist."
        @spec chars(xs :: charlist()) :: charlist()
        def chars(xs \\\\ [97, 98]), do: xs
      end
      """)

    assert param_schema(module, "go", "s")["default"] == "hi"
    assert param_schema(module, "go", "c")["default"] == "ab"
    assert param_schema(module, "go", "w")["default"] == ["a", "b"]
    refute Map.has_key?(param_schema(module, "go", "at"), "default")

    assert param_schema(module, "upper", "s")["default"] == "HI"
    assert param_schema(module, "upper", "c")["default"] == "CD"
    assert param_schema(module, "upper", "w")["default"] == ["C", "D"]
    refute Map.has_key?(param_schema(module, "interp", "s"), "default")
    assert param_schema(module, "chars", "xs")["default"] == "ab"
  end

  test "renders atom defaults as strings, including nested values" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Atom defaults."
        @spec go(
                a :: atom(),
                l :: list(atom()),
                m :: %{flag: atom()},
                b :: boolean(),
                ln :: list(atom() | nil),
                lu :: list(integer() | atom() | nil),
                m2 :: %{flag: atom()},
                t :: {atom(), atom()},
                ch :: charlist(),
                bad :: charlist(),
                num :: charlist()
              ) :: :ok
        def go(
              a \\\\ :ok,
              l \\\\ [:ok, :error],
              m \\\\ %{flag: :ok},
              b \\\\ true,
              ln \\\\ [:ok],
              lu \\\\ [:ok],
              m2 \\\\ %{"flag" => :ok},
              t \\\\ [:ok, :error],
              ch \\\\ "ab",
              bad \\\\ [:a],
              num \\\\ 1
            ),
            do: {a, l, m, b, ln, lu, m2, t, ch, bad, num}
      end
      """)

    assert param_schema(module, "go", "a")["default"] == "ok"
    assert param_schema(module, "go", "l")["default"] == ["ok", "error"]
    assert param_schema(module, "go", "m")["default"] == %{flag: "ok"}
    assert param_schema(module, "go", "b")["default"] == true
    assert param_schema(module, "go", "ln")["default"] == ["ok"]
    assert param_schema(module, "go", "lu")["default"] == ["ok"]
    assert param_schema(module, "go", "m2")["default"] == %{"flag" => "ok"}
    assert param_schema(module, "go", "t")["default"] == ["ok", "error"]
    assert param_schema(module, "go", "ch")["default"] == "ab"
    refute Map.has_key?(param_schema(module, "go", "bad"), "default")
    refute Map.has_key?(param_schema(module, "go", "num"), "default")
  end

  test "omits boolean and nil atom defaults" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @spec go(
                a :: atom(),
                l :: list(atom()),
                m :: %{flag: atom()},
                n :: atom() | nil,
                mn :: %{flag: atom() | nil},
                b :: boolean()
              ) :: :ok
        def go(
              a \\\\ true,
              l \\\\ [true, :ok],
              m \\\\ %{flag: false},
              n \\\\ nil,
              mn \\\\ %{flag: nil},
              b \\\\ true
            ),
            do: {a, l, m, n, mn, b}
      end
      """)

    refute Map.has_key?(param_schema(module, "go", "a"), "default")
    refute Map.has_key?(param_schema(module, "go", "l"), "default")
    refute Map.has_key?(param_schema(module, "go", "m"), "default")
    refute Map.has_key?(param_schema(module, "go", "n"), "default")
    refute Map.has_key?(param_schema(module, "go", "mn"), "default")
    assert param_schema(module, "go", "b")["default"] == true
  end

  test "does not warn when omitting atom boolean and nil defaults" do
    {module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall

        @spec go(
                a :: atom(),
                b :: %{flag: atom()},
                c :: {atom()},
                d :: atom() | String.t(),
                e :: list(atom()),
                f :: {atom()},
                g :: {atom() | String.t()}
              ) :: :ok
        def go(
              a \\\\ true,
              b \\\\ %{flag: nil},
              c \\\\ [true],
              d \\\\ false,
              e \\\\ [true],
              f \\\\ [true, false],
              g \\\\ [true, false]
            ),
            do: {a, b, c, d, e, f, g}
      end
      """)

    refute warnings =~ "default for parameter"
    refute Map.has_key?(param_schema(module, "go", "a"), "default")
    refute Map.has_key?(param_schema(module, "go", "b"), "default")
    refute Map.has_key?(param_schema(module, "go", "c"), "default")
    refute Map.has_key?(param_schema(module, "go", "d"), "default")
    refute Map.has_key?(param_schema(module, "go", "e"), "default")
    refute Map.has_key?(param_schema(module, "go", "f"), "default")
    refute Map.has_key?(param_schema(module, "go", "g"), "default")
  end

  test "warns for a non-atom mismatched tuple default" do
    {_module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall

        @spec go(x :: {String.t()}) :: :ok
        def go(x \\\\ [true, false]), do: x
      end
      """)

    assert warnings =~ "default for parameter \"x\""
  end

  test "drops defaults that do not belong to the parameter type" do
    {module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall

        @spec go(x :: integer(), b :: nonempty_binary()) :: term()
        def go(x \\\\ "x", b \\\\ ""), do: {x, b}
      end
      """)

    assert warnings =~ ~s(default for parameter "x" of go/2 is not compatible)
    assert warnings =~ ~s(default for parameter "b" of go/2 is not compatible)
    refute Map.has_key?(param_schema(module, "go", "x"), "default")
    refute Map.has_key?(param_schema(module, "go", "b"), "default")
  end

  test "drops object defaults outside the parameter domain" do
    {module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall

        @spec go(
                missing :: %{a: integer(), b: integer()},
                wrong :: %{a: integer()},
                extra :: %{a: integer()}
              ) :: term()
        def go(
              missing \\\\ %{a: 1},
              wrong \\\\ %{a: "bad"},
              extra \\\\ %{a: 1, b: 2}
            ),
            do: {missing, wrong, extra}
      end
      """)

    assert warnings =~ ~s(default for parameter "missing" of go/3 is not compatible)
    assert warnings =~ ~s(default for parameter "wrong" of go/3 is not compatible)
    assert warnings =~ ~s(default for parameter "extra" of go/3 is not compatible)
    refute Map.has_key?(param_schema(module, "go", "missing"), "default")
    refute Map.has_key?(param_schema(module, "go", "wrong"), "default")
    refute Map.has_key?(param_schema(module, "go", "extra"), "default")
  end

  test "renders keyword defaults as objects" do
    {module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall

        @spec go(
                good :: keyword(integer()),
                atom :: keyword(atom()),
                empty :: keyword(),
                bad :: keyword(integer())
              ) :: term()
        def go(
              good \\\\ [a: 1, b: 2],
              atom \\\\ [mode: :fast],
              empty \\\\ [],
              bad \\\\ [a: "bad"]
            ),
            do: {good, atom, empty, bad}
      end
      """)

    assert warnings =~ ~s(default for parameter "bad" of go/4 is not compatible)
    assert param_schema(module, "go", "good")["default"] == %{a: 1, b: 2}
    assert param_schema(module, "go", "atom")["default"] == %{mode: "fast"}
    assert param_schema(module, "go", "empty")["default"] == %{}
    refute Map.has_key?(param_schema(module, "go", "bad"), "default")
  end

  test "drops keyword defaults that cannot be represented" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @spec go(
                lazy :: keyword(integer()),
                malformed :: keyword(integer()),
                non_list :: keyword(integer())
              ) :: term()
        def go(
              lazy \\\\ [a: DateTime.utc_now()],
              malformed \\\\ [1],
              non_list \\\\ :bad
            ),
            do: {lazy, malformed, non_list}
      end
      """)

    refute Map.has_key?(param_schema(module, "go", "lazy"), "default")
    refute Map.has_key?(param_schema(module, "go", "malformed"), "default")
    refute Map.has_key?(param_schema(module, "go", "non_list"), "default")
  end

  test "renders defaults for keyword values inside unions" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @spec go(
                opts :: keyword(integer()) | String.t(),
                object :: %{opts: keyword(integer()) | String.t()},
                list :: list(keyword(integer()) | String.t())
              ) :: term()
        def go(
              opts \\\\ [a: 1],
              object \\\\ %{opts: [b: 2]},
              list \\\\ [[c: 3]]
            ),
            do: {opts, object, list}
      end
      """)

    assert param_schema(module, "go", "opts")["default"] == %{a: 1}
    assert param_schema(module, "go", "object")["default"] == %{opts: %{b: 2}}
    assert param_schema(module, "go", "list")["default"] == [%{c: 3}]
  end

  test "expands module attributes in defaults" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @default 3
        @opts [a: 1]

        @spec go(
                n :: integer(),
                opts :: keyword(integer()),
                nested :: %{n: integer()}
              ) :: term()
        def go(n \\\\ @default, opts \\\\ @opts, nested \\\\ %{n: @default}), do: {n, opts, nested}
      end
      """)

    assert param_schema(module, "go", "n")["default"] == 3
    assert param_schema(module, "go", "opts")["default"] == %{a: 1}
    assert param_schema(module, "go", "nested")["default"] == %{n: 3}
  end

  test "does not expand struct module attributes into defaults" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @date_default ~D[2024-01-01]

        @spec go(x :: term()) :: term()
        def go(x \\\\ @date_default), do: x
      end
      """)

    refute Map.has_key?(param_schema(module, "go", "x"), "default")
  end

  test "drops incompatible defaults inside unions" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @spec go(x :: integer() | String.t()) :: term()
        def go(x \\\\ {:bad}), do: x
      end
      """)

    refute Map.has_key?(param_schema(module, "go", "x"), "default")
  end

  test "renders nested keyword defaults" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @spec go(
                object :: %{opts: keyword(integer())},
                list :: list(keyword(atom()))
              ) :: term()
        def go(
              object \\\\ %{opts: [a: 1]},
              list \\\\ [[mode: :fast]]
            ),
            do: {object, list}
      end
      """)

    assert param_schema(module, "go", "object")["default"] == %{opts: %{a: 1}}
    assert param_schema(module, "go", "list")["default"] == [%{mode: "fast"}]
  end

  test "keeps generic map and list defaults when the type is unconstrained" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @spec go(map :: term(), list :: term()) :: term()
        def go(map \\\\ %{a: 1}, list \\\\ [1, {2, 3}]), do: {map, list}
      end
      """)

    assert param_schema(module, "go", "map")["default"] == %{a: 1}
    refute Map.has_key?(param_schema(module, "go", "list"), "default")
  end

  test "applies doc bullets to duplicate renamed parameters" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @doc \"\"\"
        Go.

        ## Parameters
          * `city` - city name
        \"\"\"
        @spec go(city :: String.t(), city :: integer()) :: term()
        def go(city, count), do: {city, count}
      end
      """)

    assert param_schema(module, "go", "city")["description"] == "city name"
    assert param_schema(module, "go", "city_2")["description"] == "city name"
  end

  test "drops map defaults whose keys JSON cannot represent" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @spec go(m :: map(), l :: list(map())) :: term()
        def go(m \\\\ %{1 => "x"}, l \\\\ [%{1 => "x"}]), do: {m, l}
      end
      """)

    refute Map.has_key?(param_schema(module, "go", "m"), "default")
    refute Map.has_key?(param_schema(module, "go", "l"), "default")
  end

  test "keeps negative literal defaults" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Negative defaults."
        @spec go(n :: integer(), m :: map()) :: :ok
        def go(n \\\\ -5, m \\\\ %{a: -1}), do: {n, m}
      end
      """)

    assert param_schema(module, "go", "n")["default"] == -5
    assert param_schema(module, "go", "m")["default"] == %{a: -1}
  end

  test "a default of :error is a value, not the absence of a default" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Error default."
        @spec go(x :: atom()) :: atom()
        def go(x \\\\ :error), do: x
      end
      """)

    assert param_schema(module, "go", "x")["default"] == "error"
    assert hd(ToolCall.emit(module, :openai))["function"]["parameters"]["required"] == []
    assert ToolCall.run(module, "go", %{}) == {:ok, :error}
  end

  test "resolves a type variable constrained by when" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Identity."
        @spec id(value) :: value when value: integer()
        def id(value), do: value
      end
      """)

    assert param_schema(module, "id", "value") == %{"type" => "integer"}
    assert ToolCall.run(module, "id", %{"value" => 1.0}) == {:ok, 1}
  end

  test "a when constraint applies inside a local type" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @type box(t) :: {t, t}

        @doc "Pair."
        @spec pair(x :: box(v)) :: {integer(), integer()} when v: integer()
        def pair(x), do: x
      end
      """)

    assert param_schema(module, "pair", "x") == %{
             "type" => "array",
             "prefixItems" => [%{"type" => "integer"}, %{"type" => "integer"}],
             "minItems" => 2,
             "maxItems" => 2
           }
  end

  test "resolves a chain of when constraints in either direction" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Forward."
        @spec forward(x) :: x when x: [t], t: integer()
        def forward(x), do: x

        @doc "Backward."
        @spec backward(x) :: x when t: integer(), x: [t]
        def backward(x), do: x
      end
      """)

    assert param_schema(module, "forward", "x") == %{
             "type" => "array",
             "items" => %{"type" => "integer"}
           }

    assert param_schema(module, "backward", "x") == %{
             "type" => "array",
             "items" => %{"type" => "integer"}
           }
  end

  test "exposes the pure spec and warning-location helpers" do
    assert ToolCall.Builder.spec_signature({:not_a_spec, [], []}) == nil
    assert ToolCall.Builder.spec_signature({:"::", [], [{:go, [], []}, :ok]}) == {:go, 0}

    assert ToolCall.Builder.constraint_bindings([{:x, {:integer, [], []}}, :bad]) == %{
             x: {:integer, [], []}
           }

    assert ToolCall.Builder.warn_location({nil, nil}) == []
    assert ToolCall.Builder.warn_location({"file.ex", nil}) == [file: "file.ex"]
    assert ToolCall.Builder.warn_location({"file.ex", 3}) == [file: "file.ex", line: 3]
  end

  test "resolves __MODULE__ in a local type and as a literal" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @type t :: integer()

        @doc "Module type."
        @spec go(x :: __MODULE__.t()) :: :ok
        def go(_x), do: :ok

        @doc "Bare module."
        @spec bare(x :: __MODULE__) :: __MODULE__
        def bare(x), do: x
      end
      """)

    assert param_schema(module, "go", "x") == %{"type" => "integer"}

    assert param_schema(module, "bare", "x") == %{
             "type" => "string",
             "enum" => [Atom.to_string(module)]
           }
  end

  test "a nil @tool_param description keeps the doc description" do
    assert param_schema(ToolCall.BuilderNilDescription, "go", "x")["description"] ==
             "documented"
  end

  test "warns and skips a function without a @spec" do
    {module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "No spec."
        def go(x), do: x
      end
      """)

    assert warnings =~ "go/1 has no @spec; skipped"
    assert ToolCall.tools(module) == []
  end

  test "names an unnamed spec argument from a defaulted or pattern head" do
    {module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Defaulted head."
        @spec a(String.t()) :: String.t()
        def a(x \\\\ "x"), do: x

        @doc "Pattern head."
        @spec b(String.t()) :: map()
        def b(%{} = map), do: map
      end
      """)

    assert param_schema(module, "a", "x") == %{"type" => "string", "default" => "x"}
    assert param_schema(module, "b", "arg1") == %{"type" => "string"}
    assert warnings =~ "has no name"
  end

  test "drops a default with a non-literal element or value" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "List."
        @spec l(xs :: list(integer())) :: list(integer())
        def l(xs \\\\ [1, DateTime.utc_now()]), do: xs

        @doc "Map."
        @spec m(m :: map()) :: map()
        def m(m \\\\ %{a: DateTime.utc_now()}), do: m
      end
      """)

    refute Map.has_key?(param_schema(module, "l", "xs"), "default")
    refute Map.has_key?(param_schema(module, "m", "m"), "default")
  end

  test "ignores private functions" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Public."
        @spec go(x :: integer()) :: integer()
        def go(x), do: helper(x)

        defp helper(x), do: x
      end
      """)

    assert ToolCall.tool_names(module) == ["go"]
  end

  test "points at a reduced-arity spec instead of claiming there is none" do
    {module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Reduced arity."
        @spec go(integer()) :: integer()
        def go(a, b \\\\1), do: a + b
      end
      """)

    assert warnings =~ "go/2 has no @spec; found go/1 instead"
    assert warnings =~ "add a spec for the full arity"
    assert ToolCall.tools(module) == []
  end

  test "warns about overloaded specs and keeps the first" do
    {module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Overloaded."
        @spec go(x :: integer()) :: integer()
        @spec go(x :: String.t()) :: String.t()
        def go(x), do: x
      end
      """)

    assert warnings =~ "go/1 has 2 @spec clauses; using the first one"
    assert param_schema(module, "go", "x") == %{"type" => "integer"}
  end

  test "warns about types JSON cannot express" do
    {_module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Unrepresentable."
        @spec go(p :: pid(), r :: reference(), t :: {pid(), integer()}) :: :ok
        def go(_p, _r, _t), do: :ok
      end
      """)

    assert warnings =~ ~s(parameter "p" of go/3 has no JSON representation)
    assert warnings =~ ~s(parameter "r" of go/3 has no JSON representation)
    assert warnings =~ ~s(parameter "t" of go/3 has no JSON representation)
  end

  test "stays quiet about values JSON can express" do
    {_module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Fine."
        @spec go(a :: term(), b :: atom()) :: :ok
        def go(_a, _b), do: :ok
      end
      """)

    refute warnings =~ "no JSON representation"
  end

  test "a @tool_param override applies only to the function it names" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "A."
        @tool_param %{fun: :a, name: "user_id", wire: :string_integer, description: "Snowflake id"}
        @spec a(user_id :: integer()) :: integer()
        def a(user_id), do: user_id

        @doc "B."
        @spec b(user_id :: integer()) :: integer()
        def b(user_id), do: user_id
      end
      """)

    assert param_schema(module, "a", "user_id") == %{
             "type" => "string",
             "pattern" => "^-?\\d+$",
             "description" => "Snowflake id"
           }

    assert param_schema(module, "b", "user_id") == %{"type" => "integer"}
  end

  test "the last @tool_param for the same argument wins" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "A."
        @tool_param %{fun: :a, name: "n", description: "first"}
        @tool_param %{fun: :a, name: "n", description: "second"}
        @spec a(n :: integer()) :: integer()
        def a(n), do: n
      end
      """)

    assert param_schema(module, "a", "n")["description"] == "second"
  end

  test "warns about an override for an unknown tool" do
    {module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "A."
        @tool_param %{fun: :nope, name: "n", wire: :string_integer}
        @spec a(n :: integer()) :: integer()
        def a(n), do: n
      end
      """)

    assert warnings =~ "unknown tool :nope"
    assert param_schema(module, "a", "n") == %{"type" => "integer"}
  end

  test "warns about an override for an unknown parameter" do
    {_module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "A."
        @tool_param %{fun: :a, name: "nope", wire: :string_integer}
        @spec a(n :: integer()) :: integer()
        def a(n), do: n
      end
      """)

    assert warnings =~ ~s(unknown parameter "nope" of tool :a)
  end

  test "warns about the old unscoped @tool_param form" do
    {_module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "A."
        @tool_param %{name: "n", wire: :string_integer}
        @spec a(n :: integer()) :: integer()
        def a(n), do: n
      end
      """)

    assert warnings =~ "expected @tool_param %{fun: :function, name: ...}"
  end

  test "records typedoc keys from the normalized pre-inlining type" do
    result =
      build_fixture!("""
      @type address :: String.t()

      @spec go(value :: address()) :: String.t()
      def go(value), do: value

      @doc \"\"\"
      Documented.

      ## Parameters
        * `value` - documented parameter
      \"\"\"
      @spec documented(value :: address()) :: String.t()
      def documented(value), do: value

      @tool_param %{fun: :overridden, name: "value", description: "override"}
      @spec overridden(value :: address()) :: String.t()
      def overridden(value), do: value

      @tool_param %{fun: :cleared, name: "value", description: ""}
      @spec cleared(value :: address()) :: String.t()
      def cleared(value), do: value

      @spec nullable(value :: address() | nil) :: String.t()
      def nullable(value), do: value

      @spec constrained(value) :: String.t() when value: address()
      def constrained(value), do: value

      @spec qualified(value :: __MODULE__.address()) :: String.t()
      def qualified(value), do: value

      @spec listed(value :: list(address())) :: String.t()
      def listed(value), do: value
      """)

    assert result.typedoc_keys == %{
             {"go", "value"} => [{:address, 0}],
             {"nullable", "value"} => [{:address, 0}],
             {"constrained", "value"} => [{:address, 0}],
             {"qualified", "value"} => [{:address, 0}]
           }

    refute Map.has_key?(result.typedoc_keys, {"listed", "value"})
    refute Map.has_key?(result.typedoc_keys, {"documented", "value"})
    refute Map.has_key?(result.typedoc_keys, {"overridden", "value"})
    refute Map.has_key?(result.typedoc_keys, {"cleared", "value"})

    go = Enum.find(result.tools, &(&1.name == "go"))
    assert [param] = go.params
    assert strip_meta(param.source) == {:address, [], []}
  end

  test "a default keeps the parameter optional even when it cannot be emitted" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Optional."
        @spec go(at :: DateTime.t() | nil) :: :ok
        def go(at \\\\ DateTime.utc_now()), do: at && :ok
      end
      """)

    tool = Enum.find(ToolCall.tools(module), &(&1.name == "go"))
    [param] = tool.params

    refute param.required
    assert param.default == nil
  end
end
