# reach:disable-for-this-file string_building
# $defs names are short-lived compile-time labels; iolists would obscure them
# without a runtime benefit.
defmodule ToolCall.LocalTypeAlgorithm.RefName do
  @moduledoc """
  Builds `$defs` names for a local type instantiation.

  The readable part comes from each adapter's argument naming; the terminal hash
  keeps two instantiations of the same type distinct and is a pure function of the
  type key and its arguments.
  """

  @doc false
  @spec build({atom(), non_neg_integer()}, [term()], (term() -> String.t())) :: String.t()
  def build({type_name, _arity} = key, args, arg_name_fun) do
    case Enum.map(args, arg_name_fun) do
      [] ->
        sanitize(Atom.to_string(type_name))

      parts ->
        sanitize(
          Atom.to_string(type_name) <>
            "_" <> Enum.join(parts, "_") <> "_" <> signature(key, args)
        )
    end
  end

  defp sanitize(name) do
    sanitized =
      name
      |> String.replace(~r/[^A-Za-z0-9_]/, "_")
      |> String.slice(0, 64)
      |> String.trim_trailing("_")

    if sanitized == "", do: "type", else: sanitized
  end

  defp signature(key, args) do
    key
    |> then(&{&1, args})
    |> :erlang.phash2()
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.slice(0, 4)
  end
end
