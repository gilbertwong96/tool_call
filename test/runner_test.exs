defmodule ToolCall.RunnerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import ToolCall.TestModule

  defp pair_tool do
    compile!("""
    defmodule FIXTURE do
      use ToolCall

      @doc "Both arguments have defaults."
      @spec pair(a :: integer(), b :: integer()) :: {integer(), integer()}
      def pair(a \\\\ 1, b \\\\ 2), do: {a, b}
    end
    """)
  end

  test "fills trailing defaults when earlier arguments are omitted" do
    module = pair_tool()

    assert {:ok, {1, 2}} = ToolCall.run(module, :pair, %{})
    assert {:ok, {5, 2}} = ToolCall.run(module, :pair, %{"a" => 5})
    assert {:ok, {5, 7}} = ToolCall.run(module, :pair, %{"a" => 5, "b" => 7})
  end

  test "supports non-trailing defaults that Elixir can still position" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @spec f(a :: integer(), b :: integer()) :: {integer(), integer()}
        def f(a \\\\ 1, b), do: {a, b}

        @spec g(a :: integer(), b :: integer(), c :: integer()) :: {integer(), integer(), integer()}
        def g(a, b \\\\ 2, c), do: {a, b, c}

        @spec h(a :: integer(), b :: integer(), c :: integer(), d :: integer()) ::
                {integer(), integer(), integer(), integer()}
        def h(a, b \\\\ 2, c, d \\\\ 4), do: {a, b, c, d}
      end
      """)

    assert {:ok, {1, 9}} = ToolCall.run(module, :f, %{"b" => 9})
    assert {:ok, {5, 9}} = ToolCall.run(module, :f, %{"a" => 5, "b" => 9})
    assert {:error, {:missing_argument, "b"}} = ToolCall.run(module, :f, %{})
    assert {:error, {:missing_argument, "b"}} = ToolCall.run(module, :f, %{"a" => 5})

    assert {:ok, {1, 2, 3}} = ToolCall.run(module, :g, %{"a" => 1, "c" => 3})
    assert {:ok, {1, 7, 3}} = ToolCall.run(module, :g, %{"a" => 1, "b" => 7, "c" => 3})

    assert {:ok, {1, 2, 3, 4}} = ToolCall.run(module, :h, %{"a" => 1, "c" => 3})
    assert {:ok, {1, 7, 3, 4}} = ToolCall.run(module, :h, %{"a" => 1, "b" => 7, "c" => 3})

    assert {:error, {:argument_gap, "b", ["d"]}} =
             ToolCall.run(module, :h, %{"a" => 1, "c" => 3, "d" => 9})
  end

  test "rejects an optional gap even when a later optional is supplied" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @spec go(a :: integer(), b :: integer(), c :: integer()) :: {integer(), integer(), integer()}
        def go(a \\\\ 1, b \\\\ 2, c \\\\ 3), do: {a, b, c}
      end
      """)

    assert {:error, {:argument_gap, "b", ["c"]}} =
             ToolCall.run(module, :go, %{"a" => 1, "c" => 3})
  end

  test "restores tuple arguments" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @spec pair(pair :: {integer(), String.t()}) :: {integer(), String.t()}
        def pair({x, y}), do: {x, y}

        @spec nested(pair :: {{integer(), integer()}, String.t()}) :: term()
        def nested({{x, y}, z}), do: {x, y, z}
      end
      """)

    assert {:ok, {1, "a"}} = ToolCall.run(module, :pair, %{"pair" => [1.0, "a"]})
    assert {:ok, {1, 2, "a"}} = ToolCall.run(module, :nested, %{"pair" => [[1.0, 2], "a"]})
  end

  test "restores char arguments as codepoints" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @spec char(c :: char()) :: integer()
        def char(c), do: c
      end
      """)

    assert {:ok, ?a} = ToolCall.run(module, :char, %{"c" => "a"})
    assert {:ok, ?\n} = ToolCall.run(module, :char, %{"c" => "\n"})
    assert {:ok, ?é} = ToolCall.run(module, :char, %{"c" => "é"})
    assert {:error, _reason} = ToolCall.run(module, :char, %{"c" => "ab"})
  end

  test "prepares runtime char patterns with unicode" do
    module =
      compile!("""
      defmodule FIXTURE do
        def char(c), do: c
      end
      """)

    tool = %ToolCall.IR.Tool{
      name: "char",
      params: [
        %ToolCall.IR.Param{
          name: "c",
          type: ToolCall.Typespec.to_type({:char, [], []})
        }
      ],
      module: module,
      fun: :char
    }

    assert {:ok, ?é} = ToolCall.Runner.run(module, [tool], "char", %{"c" => "é"})
  end

  test "hands calendar arguments over as structs" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @spec started(at :: Date.t(), since :: DateTime.t()) :: map()
        def started(at, since), do: %{date: Date.to_iso8601(at), utc: DateTime.to_iso8601(since)}
      end
      """)

    assert {:ok, %{date: "2024-01-31", utc: "2024-01-31T10:30:00Z"}} =
             ToolCall.run(module, :started, %{
               "at" => "2024-01-31",
               "since" => "2024-01-31T10:30:00Z"
             })
  end

  @tag capture_log: true
  test "logs a raised exception with its stacktrace" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Raises."
        @spec boom() :: no_return()
        def boom, do: raise("kaboom")
      end
      """)

    log =
      capture_log(fn ->
        assert {:error, {:raised, "kaboom"}} = ToolCall.run(module, :boom, %{})
      end)

    assert log =~ "** (RuntimeError) kaboom"
    assert log =~ "runner.ex"
  end

  test "restores the value domain of map and keyword arguments" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @spec move(point :: %{x: integer(), y: integer()}, opts :: keyword(String.t())) :: map()
        def move(point, opts), do: %{point: point, unit: Keyword.get(opts, :unit)}
      end
      """)

    assert {:ok, %{point: %{x: 1, y: 2}, unit: "m"}} =
             ToolCall.run(module, :move, %{
               "point" => %{"x" => 1.0, "y" => 2},
               "opts" => %{"unit" => "m"}
             })
  end

  test "treats an explicit null for an optional argument as absent" do
    module = pair_tool()

    assert {:ok, {5, 2}} = ToolCall.run(module, :pair, %{"a" => 5, "b" => nil})
    # Null means absent, so `b` cannot be positioned after the omitted `a`.
    assert {:error, {:argument_gap, "a", ["b"]}} =
             ToolCall.run(module, :pair, %{"a" => nil, "b" => 7})

    assert {:ok, {1, 2}} = ToolCall.run(module, :pair, %{"a" => nil, "b" => nil})
  end

  test "rejects an argument that would be dropped by a positional gap" do
    module = pair_tool()

    assert {:error, {:argument_gap, "a", ["b"]}} =
             ToolCall.run(module, :pair, %{"b" => 99})
  end

  test "returns an error for arguments that are not a map" do
    module = pair_tool()

    assert {:error, {:invalid_arguments, [1, 2]}} = ToolCall.run(module, :pair, [1, 2])
    assert {:error, {:invalid_arguments, nil}} = ToolCall.run(module, :pair, nil)
  end

  test "accepts every branch of an integer union" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @spec wide(x :: integer() | 1..10) :: integer()
        def wide(x), do: x

        @spec split(x :: pos_integer() | neg_integer()) :: integer()
        def split(x), do: x
      end
      """)

    assert {:ok, 0} = ToolCall.run(module, :wide, %{"x" => 0})
    assert {:ok, 100} = ToolCall.run(module, :wide, %{"x" => 100})
    assert {:ok, -5} = ToolCall.run(module, :split, %{"x" => -5})
    assert {:ok, 5} = ToolCall.run(module, :split, %{"x" => 5})
    assert {:error, _reason} = ToolCall.run(module, :split, %{"x" => 0})
  end

  test "treats nil params on a runtime tool as an empty list" do
    module =
      compile!("""
      defmodule FIXTURE do
        def ping, do: :pong
      end
      """)

    tool = %ToolCall.IR.Tool{name: "ping", params: nil, module: module, fun: :ping}
    assert {:ok, :pong} = ToolCall.Runner.run(module, [tool], "ping", %{})
  end

  test "validates and prepares runtime tools" do
    module =
      compile!("""
      defmodule FIXTURE do
        def ping(value), do: value
      end
      """)

    tool = %ToolCall.IR.Tool{
      name: "ping",
      params: [
        %ToolCall.IR.Param{
          name: "value",
          type: %ToolCall.IR.Type{kind: :string, pattern: "^x$"}
        }
      ],
      module: module,
      fun: :ping
    }

    prepared = ToolCall.Typespec.validate_tool!(tool)

    assert %ToolCall.IR.Tool{
             params: [
               %ToolCall.IR.Param{
                 type: %ToolCall.IR.Type{pattern_regex: %Regex{}}
               }
             ]
           } = prepared

    assert {:ok, "x"} = ToolCall.Runner.run(module, [tool], "ping", %{"value" => "x"})
  end

  test "rejects non-map arguments through the validating entry" do
    assert {:error, {:invalid_arguments, "bad"}} =
             ToolCall.Runner.run(__MODULE__, [], "ping", "bad")
  end

  test "rejects non-string keys instead of reporting a known name as unknown" do
    module = pair_tool()

    assert {:error, {:non_string_arguments, [:a]}} = ToolCall.run(module, :pair, %{a: 1})
    assert {:error, {:non_string_arguments, [1]}} = ToolCall.run(module, :pair, %{1 => 1})
  end

  test "reports the tool list when the name is unknown" do
    module = pair_tool()

    assert {:error, {:unknown_tool, "nope", ["pair"]}} =
             ToolCall.run(module, :nope, %{})
  end

  @tag capture_log: true
  test "wraps a raised exception" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Raises."
        @spec boom() :: no_return()
        def boom, do: raise("kaboom")
      end
      """)

    assert {:error, {:raised, "kaboom"}} = ToolCall.run(module, :boom, %{})
  end

  test "wraps an exit" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Exits."
        @spec bail() :: no_return()
        def bail, do: exit(:nope)
      end
      """)

    assert {:error, {:exited, :nope}} = ToolCall.run(module, :bail, %{})
  end

  test "wraps a thrown value" do
    module =
      compile!("""
      defmodule FIXTURE do
        use ToolCall

        @doc "Throws."
        @spec toss() :: no_return()
        def toss, do: throw(:nope)
      end
      """)

    assert {:error, {:thrown, :nope}} = ToolCall.run(module, :toss, %{})
  end
end
