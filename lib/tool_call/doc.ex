defmodule ToolCall.Doc do
  @moduledoc """
  Extracts tool descriptions from `@doc` strings.

  `@doc` is free-form markdown. The first paragraph becomes the tool
  description; a leading `#` title is stripped, while a leading level-2+
  section heading is omitted and its body is used. Bullets under a
  `## Parameters` heading (also `Params`, `Options`, `Arguments` and `Args`)
  become per-parameter descriptions, with an optional type annotation such as
  `* city (String.t()) - city name`. `## Options` conventionally documents the
  keys of a keyword argument, so those bullets are not matched against parameter
  names, do not name a parameter by position and do not warn; the section is not
  part of the tool description.

      @doc \"\"\"
      Get the forecast.

      ## Parameters
        * `city` - city name
        * `days` - forecast days
      \"\"\"
  """

  @param_heading ~r/^\s{0,3}#+\s*(parameters|params|options|arguments|args)\s*:?\s*$/i
  @any_heading ~r/^\s{0,3}#+\s+/
  @bullet ~r/^\s*[+*-]\s+`?([\w.?!]+)`?(?:\s*\([^()\n]*(?:\([^()\n]*\)[^()\n]*)*\))?\s*[-–—:]\s*(.+?)\s*$/u

  @type parsed :: %{
          description: String.t() | nil,
          params: %{String.t() => String.t()},
          param_order: [String.t()],
          param_heading: :parameters | :options | nil
        }

  @spec parse(nil | false | String.t()) :: parsed()
  def parse(nil), do: %{description: nil, params: %{}, param_order: [], param_heading: nil}
  def parse(false), do: %{description: nil, params: %{}, param_order: [], param_heading: nil}

  def parse(text) when is_binary(text) do
    {params, heading} = params(text)

    %{
      description: description(text),
      params: Map.new(params),
      param_order: if(heading == :options, do: [], else: Enum.map(params, &elem(&1, 0))),
      param_heading: heading
    }
  end

  defp description(text) do
    text
    |> String.split(~r/\n\s*\n/, parts: 2)
    |> hd()
    |> description_lines()
    |> Enum.join("\n")
    |> String.trim()
    |> String.replace(~r/\A#+\s+/, "")
    |> blank_to_nil()
  end

  defp description_lines(first) do
    [first_line | rest] = String.split(first, "\n")
    rest = Enum.take_while(rest, &(not Regex.match?(@any_heading, &1)))

    cond do
      Regex.match?(@param_heading, first_line) -> []
      level_one_heading?(first_line) -> [first_line | rest]
      Regex.match?(@any_heading, first_line) -> rest
      true -> [first_line | rest]
    end
  end

  defp level_one_heading?(line), do: Regex.match?(~r/^\s{0,3}#\s+/, line)

  defp params(text) do
    case text
         |> String.split("\n")
         |> Enum.split_while(&(not Regex.match?(@param_heading, &1))) do
      {_before, [heading | rest]} ->
        {rest |> Enum.take_while(&(not Regex.match?(@any_heading, &1))) |> collect_params(),
         heading_kind(heading)}

      {_before, []} ->
        {[], nil}
    end
  end

  # `## Options` conventionally documents the keys of a keyword argument, which
  # are not function parameters; the builder does not warn about those bullets.
  defp heading_kind(line) do
    if Regex.match?(~r/options/i, line), do: :options, else: :parameters
  end

  # Only bullets at the indentation of the first bullet are parameters; a
  # nested bullet is prose, not a second argument the function does not have.
  # Its continuation must not be appended to the previous parameter either.
  defp collect_params(lines) do
    {acc, _base, _last} = Enum.reduce(lines, {[], nil, :none}, &collect_param/2)
    Enum.reverse(acc)
  end

  defp collect_param(line, state) do
    case Regex.run(@bullet, line) do
      [_, name, description] -> collect_bullet(line, name, description, state)
      _ -> collect_text(line, state)
    end
  end

  defp collect_bullet(line, name, description, {acc, base, _last}) do
    indent = indent(line)
    entry = {name, String.trim(description)}

    cond do
      base == nil -> {[entry | acc], indent, :accepted}
      indent == base -> {[entry | acc], base, :accepted}
      true -> {acc, base, :ignored}
    end
  end

  defp collect_text(line, {acc, base, last}) do
    text = continuation(line)

    cond do
      bullet_like?(line) -> {acc, base, :ignored}
      last == :accepted and text != nil -> {append_continuation(acc, text), base, last}
      last == :accepted -> {acc, base, :none}
      true -> {acc, base, last}
    end
  end

  defp bullet_like?(line), do: String.match?(String.trim(line), ~r/^[*+-](\s|$)/)

  defp indent(line), do: byte_size(line) - byte_size(String.trim_leading(line))

  defp append_continuation([{name, description} | rest], text) do
    [{name, description <> " " <> text} | rest]
  end

  defp continuation(line) do
    text = String.trim(line)

    if String.match?(line, ~r/^\s+\S/) and not String.match?(text, ~r/^[*+-](\s|$)/) do
      blank_to_nil(text)
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text
end
