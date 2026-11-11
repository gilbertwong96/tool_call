defmodule ToolCall.Providers.Version do
  @moduledoc """
  Optional provider for `t:Version.t/0`, encoded as a semantic-version string.

  Enable it per tool module:

      use ToolCall, types: [ToolCall.Providers.Version]

  The schema is a plain string; dispatch parses it with `Version.parse/1` and
  passes a `%Version{}` to the function. Invalid values become
  `{:invalid_argument, {name, {:invalid_version, value}}}`.
  """

  @behaviour ToolCall.TypeProvider

  alias ToolCall.IR.Type

  @impl true
  def resolve(Elixir.Version, :t, []),
    do: {:ok, %Type{kind: :string, source: {Elixir.Version, :t}}}

  def resolve(_module, _function, _args), do: :error

  @impl true
  def coerce(value) when is_binary(value) do
    case Elixir.Version.parse(value) do
      {:ok, version} -> {:ok, version}
      :error -> {:error, {:invalid_version, value}}
    end
  end

  def coerce(other), do: {:error, {:expected_string, other}}

  @impl true
  def validate(_type, %Elixir.Version{}, _defs), do: true
  def validate(_type, _value, _defs), do: false
end
