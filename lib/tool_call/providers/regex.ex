defmodule ToolCall.Providers.Regex do
  @moduledoc false
  # `Regex.t/0` exposes `re_pattern`, which is a compiled opaque term a model
  # cannot produce. A regex travels as its source string, compiled at dispatch
  # with the `u` flag so a model-written pattern matches Unicode by default.

  @behaviour ToolCall.TypeProvider

  alias ToolCall.IR.Type

  @impl true
  def resolve(Regex, :t, []), do: {:ok, %Type{kind: :string, source: {Regex, :t}}}
  def resolve(_module, _function, _args), do: :error

  @impl true
  def validate(_type, %Regex{}, _defs), do: true
  def validate(_type, _value, _defs), do: false

  @impl true
  def coerce(source) when is_binary(source) do
    case Regex.compile(source, "u") do
      {:ok, regex} -> {:ok, regex}
      {:error, {message, position}} -> {:error, {:invalid_regex, message, position}}
    end
  end

  def coerce(other), do: {:error, {:expected_string, other}}
end
