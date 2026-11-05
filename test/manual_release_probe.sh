#!/usr/bin/env bash
# Manual full-release probe for the typedoc companion.
#
# This is not part of `mix test` or `mix ci`: it builds a temporary Mix project
# with a path dependency on this checkout, assembles a production release, and
# evaluates the public API from the assembled release. See docs/design.md.
#
# Usage: test/manual_release_probe.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/tool_call_release_probe.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT

mkdir -p "$probe_dir/lib"

cat > "$probe_dir/mix.exs" <<EOF
defmodule TypedocProbe.MixProject do
  use Mix.Project

  def project do
    [
      app: :typedoc_probe,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [{:tool_call, path: "$root"}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
EOF

cat > "$probe_dir/lib/probe.ex" <<'EOF'
defmodule TypedocProbe do
  use ToolCall

  @typedoc "Postal address"
  @type address :: String.t()

  @doc "Send a parcel."
  @spec send(to :: address()) :: :ok
  def send(_to), do: :ok
end
EOF

(
  cd "$probe_dir"
  mix deps.get >/dev/null
  MIX_ENV=prod mix release --overwrite >/dev/null
)

release_dir="$probe_dir/_build/prod/rel/typedoc_probe"
companion="$release_dir/lib/typedoc_probe-0.1.0/ebin/Elixir.TypedocProbe.__ToolCall__.beam"

test -f "$companion"
echo "companion beam: ${companion#"$probe_dir"/}"

output="$(
  "$release_dir/bin/typedoc_probe" eval '
    schema = ToolCall.emit(TypedocProbe, :openai)
    description = get_in(schema, [Access.at(0), "function", "parameters", "properties", "to", "description"])
    IO.inspect(description, label: "description")
    IO.inspect(ToolCall.run(TypedocProbe, :send, %{"to" => "Oslo"}), label: "run")
    IO.inspect(Code.fetch_docs(TypedocProbe), label: "docs")
    IO.inspect(Code.Typespec.fetch_specs(TypedocProbe), label: "specs")
  '
)"

printf '%s\n' "$output"

grep -qx 'description: "Postal address"' <<<"$output"
grep -qx 'run: {:ok, :ok}' <<<"$output"
grep -qx 'docs: {:error, :chunk_not_found}' <<<"$output"
grep -qx 'specs: :error' <<<"$output"
