defmodule ToolCallBench.Tools do
  use ToolCall

  @doc "Add two integers."
  @spec add(a :: integer(), b :: integer()) :: integer()
  def add(a, b), do: a + b

  @doc "Describe a user."
  @spec describe(name :: String.t(), age :: pos_integer() | nil, tags :: [String.t()]) ::
          %{name: String.t(), age: pos_integer() | nil, tags: [String.t()]}
  def describe(name, age, tags), do: %{name: name, age: age, tags: tags}
end

defmodule ToolCallBench.Many do
  use ToolCall

  for n <- 1..10 do
    @doc "Add two integers."
    @spec unquote(:"add#{n}")(a :: integer(), b :: integer()) :: integer()
    def unquote(:"add#{n}")(a, b), do: a + b
  end
end
