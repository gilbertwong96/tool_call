defmodule ToolCall.Providers.URI do
  @moduledoc """
  Optional provider for `t:URI.t/0`, encoded as a string.

  Enable it per tool module:

      use ToolCall, types: [ToolCall.Providers.URI]

  The schema is a plain string; dispatch parses it with `URI.new/1` and passes
  a `%URI{}` to the function. Invalid values become
  `{:invalid_argument, {name, {:invalid_uri, reason}}}`.
  """

  @behaviour ToolCall.TypeProvider

  alias ToolCall.IR.Type

  @impl true
  def resolve(Elixir.URI, :t, []),
    do: {:ok, %Type{kind: :string, source: {Elixir.URI, :t}}}

  def resolve(_module, _function, _args), do: :error

  @impl true
  def coerce(value) when is_binary(value) do
    case Elixir.URI.new(value) do
      {:ok, uri} -> {:ok, uri}
      {:error, reason} -> {:error, {:invalid_uri, reason}}
    end
  end

  def coerce(other), do: {:error, {:expected_string, other}}

  @impl true
  def validate(_type, %Elixir.URI{}, _defs), do: true
  def validate(_type, _value, _defs), do: false
end
