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

  test "warns that Decimal travels as a string, and constrains it to one" do
    {module, warnings} =
      compile_with_warnings!("""
      defmodule FIXTURE do
        use ToolCall

        @spec go(amount :: Decimal.t()) :: atom()
        def go(_amount), do: :ok
      end
      """)

    assert warnings =~ "Decimal"

    assert param_schema(module, "go", "amount") == %{
             "type" => "string",
             "pattern" => ~S"^-?\d+(\.\d+)?([eE][+-]?\d+)?$"
           }

    assert {:ok, :ok} = ToolCall.run(module, :go, %{"amount" => "1.50"})
    assert {:error, _reason} = ToolCall.run(module, :go, %{"amount" => "1,50"})
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
    assert_raise ArgumentError, ~r/accepts no options/, fn ->
      compile!("""
      defmodule FIXTURE do
        use ToolCall, emit: [:openai]
      end
      """)
    end
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
                t :: {atom(), atom()},
                ch :: charlist(),
                bad :: charlist(),
                num :: charlist()
              ) :: :ok
        def go(
              a \\\\ true,
              l \\\\ [true, :ok],
              m \\\\ %{flag: false},
              b \\\\ true,
              ln \\\\ [nil, true],
              lu \\\\ [nil, true],
              t \\\\ [true, false],
              ch \\\\ "ab",
              bad \\\\ [:a],
              num \\\\ 1
            ),
            do: {a, l, m, b, ln, lu, t, ch, bad, num}
      end
      """)

    assert param_schema(module, "go", "a")["default"] == "true"
    assert param_schema(module, "go", "l")["default"] == ["true", "ok"]
    assert param_schema(module, "go", "m")["default"] == %{flag: "false"}
    assert param_schema(module, "go", "b")["default"] == true
    assert param_schema(module, "go", "ln")["default"] == [nil, "true"]
    assert param_schema(module, "go", "lu")["default"] == [nil, "true"]
    assert param_schema(module, "go", "t")["default"] == ["true", "false"]
    assert param_schema(module, "go", "ch")["default"] == "ab"
    refute Map.has_key?(param_schema(module, "go", "bad"), "default")
    refute Map.has_key?(param_schema(module, "go", "num"), "default")
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

  test "expands __MODULE__ in a type" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @type t :: integer()

        @doc "Module type."
        @spec go(x :: __MODULE__.t()) :: :ok
        def go(_x), do: :ok
      end
      """)

    # `__MODULE__.t()` is a remote reference, not a local alias, so it degrades.
    assert param_schema(module, "go", "x") == %{}
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
