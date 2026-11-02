defmodule ToolCall.Doc do
  @moduledoc """
  Extracts tool descriptions from `@doc` strings.

  `@doc` is free-form markdown, so this module only understands one
  convention: the first paragraph becomes the tool description (a leading
  markdown heading marker is stripped), and bullets under a `## Parameters`
  heading become per-parameter descriptions.

      @doc \"\"\"
      Get the forecast.

      ## Parameters
        * `city` - city name
        * `days` - forecast days
      \"\"\"
  """

  @param_heading ~r/^#+\s*(parameters|params|options|arguments|args)\s*$/i
  @any_heading ~r/^#+\s+/
  @bullet ~r/^\s*[*-]\s+`?([A-Za-z0-9_.]+)`?\s*[-–—:]\s*(.+?)\s*$/

  @type parsed :: %{description: String.t() | nil, params: %{String.t() => String.t()}}

  @spec parse(nil | false | String.t()) :: parsed()
  def parse(nil), do: %{description: nil, params: %{}}
  def parse(false), do: %{description: nil, params: %{}}

  def parse(text) when is_binary(text) do
    %{description: description(text), params: params(text)}
  end

  defp description(text) do
    text
    |> String.split(~r/\n\s*\n/, parts: 2)
    |> hd()
    |> String.trim()
    |> String.replace(~r/\A#+\s+/, "")
    |> blank_to_nil()
  end

  defp params(text) do
    text
    |> String.split("\n")
    |> Enum.drop_while(&(not Regex.match?(@param_heading, &1)))
    |> Enum.drop(1)
    |> Enum.take_while(&(not Regex.match?(@any_heading, &1)))
    |> collect_params()
    |> Map.new()
  end

  # Only bullets at the indentation of the first bullet are parameters; a
  # nested bullet is prose, not a second argument the function does not have.
  # Its continuation must not be appended to the previous parameter either.
  defp collect_params(lines) do
    {acc, _base, _last} = Enum.reduce(lines, {[], nil, :none}, &collect_param/2)
    Enum.reverse(acc)
  end

  defp collect_param(line, {acc, base, last}) do
    case Regex.run(@bullet, line) do
      [_, name, description] ->
        case {base, indent(line)} do
          {nil, indent} -> {[{name, String.trim(description)} | acc], indent, :accepted}
          {base, base} -> {[{name, String.trim(description)} | acc], base, :accepted}
          _other -> {acc, base, :ignored}
        end

      _ ->
        cond do
          bullet_like?(line) -> {acc, base, :ignored}
          last == :accepted -> {append_continuation(line, acc), base, last}
          true -> {acc, base, last}
        end
    end
  end

  defp bullet_like?(line), do: String.match?(String.trim(line), ~r/^[*+-](\s|$)/)

  defp indent(line), do: byte_size(line) - byte_size(String.trim_leading(line))

  defp append_continuation(line, [{name, description} | rest]) do
    case continuation(line) do
      nil -> [{name, description} | rest]
      text -> [{name, description <> " " <> text} | rest]
    end
  end

  defp append_continuation(_line, []), do: []

  defp continuation(line) do
    text = String.trim(line)

    if String.match?(line, ~r/^\s+\S/) and not String.match?(text, ~r/^[*+-](\s|$)/) do
      blank_to_nil(text)
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text
end
