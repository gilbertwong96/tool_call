defmodule Mix.Tasks.ToolCall.Export do
  use Mix.Task

  @shortdoc "Exports the derived tool schemas as JSON"

  @moduledoc """
  Exports the schemas derived by `use ToolCall` as JSON.

      mix tool_call.export
      mix tool_call.export MyApp.Tools.Weather MyApp.Tools.Math
      mix tool_call.export --format anthropic
      mix tool_call.export --format mcp --out priv/tools.json
      mix tool_call.export --strict

  Without module arguments every module of the current application that exports
  `__tools__/0` is used; `--app` selects another application. Discovery loads
  those modules (`Code.ensure_loaded?/1`), so `@on_load` callbacks run; pass
  module names to avoid it. Output is indented JSON with sorted keys, and
  modules and tools keep a stable order, so a file checked into the repository is
  reproducible.

  ## Formats

    * `openai` (default) - an array of OpenAI function objects, i.e. the `tools`
      parameter of Chat Completions
    * `anthropic` - an array of `{name, description, input_schema}` objects
    * `mcp` - an MCP `tools/list` result:
      `{"tools": [{"name": ..., "description": ..., "inputSchema": ...}]}`

  ## Options

    * `--format`, `-f` - `openai` (default), `anthropic` or `mcp`
    * `--out`, `-o` - write to a file instead of stdout
    * `--app`, `-a` - application to discover tool modules in
    * `--strict` - emit the strict JSON Schema subset; ignored by `anthropic`

  Formatting uses `json:format/1`, so the task needs Erlang/OTP 27.1 or later;
  the rest of the library does not. The formatter belongs to OTP, so a file is
  reproducible per OTP version and may reflow after an upgrade.
  """

  @requirements ["compile"]

  @switches [app: :string, format: :string, out: :string, strict: :boolean]
  @aliases [a: :app, f: :format, o: :out]
  @formats ~w(openai anthropic mcp)

  @impl Mix.Task
  def run(argv) do
    {opts, names} = OptionParser.parse!(argv, strict: @switches, aliases: @aliases)

    format = format!(opts[:format])
    strict? = Keyword.get(opts, :strict, false)
    modules = modules(names, opts[:app])

    specs = Enum.flat_map(modules, &ToolCall.describe(&1, strict: strict?))
    validate!(specs)

    data = render(modules, format, strict?, specs)
    write(encode(data), opts[:out])
  end

  defp format!(nil), do: "openai"
  defp format!(format) when format in @formats, do: format

  defp format!(format) do
    Mix.raise("unknown format #{inspect(format)}; expected one of #{Enum.join(@formats, ", ")}")
  end

  defp modules([], app), do: discover(app || Mix.Project.config()[:app])

  defp modules(names, _app) do
    names
    |> Enum.map(&module!/1)
    |> Enum.uniq()
    |> Enum.sort_by(&Atom.to_string/1)
  end

  defp module!(name) do
    module = Module.concat([name])

    if tool_module?(module) do
      module
    else
      Mix.raise("#{name} does not use ToolCall")
    end
  end

  defp discover(nil) do
    Mix.raise("no application to discover tools in; pass module names or --app")
  end

  defp discover(app) when is_binary(app), do: discover(String.to_atom(app))

  defp discover(app) do
    case Application.load(app) do
      :ok -> :ok
      {:error, {:already_loaded, ^app}} -> :ok
      {:error, reason} -> Mix.raise("cannot load #{inspect(app)}: #{inspect(reason)}")
    end

    modules =
      app
      |> Application.spec(:modules)
      |> List.wrap()
      |> Enum.filter(&tool_module?/1)
      |> Enum.sort_by(&Atom.to_string/1)

    case modules do
      [] -> Mix.raise("no modules in #{inspect(app)} use ToolCall; pass module names explicitly")
      modules -> modules
    end
  end

  defp tool_module?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__tools__, 0)
  end

  defp validate!([]) do
    Mix.raise("no tools found; check the module names and their @spec/@doc")
  end

  defp validate!(specs) do
    validate_names!(specs)
    validate_duplicates!(specs)
  end

  defp validate_names!(specs) do
    invalid =
      specs
      |> Enum.map(& &1.name)
      |> Enum.reject(&ToolCall.ProviderName.valid?/1)

    case invalid do
      [] ->
        :ok

      names ->
        Mix.raise(
          "tool names must match #{inspect(ToolCall.ProviderName.pattern())}: " <>
            "#{Enum.join(names, ", ")}. Rename the function or hide it with @doc false."
        )
    end
  end

  defp validate_duplicates!(specs) do
    duplicates =
      specs
      |> Enum.group_by(& &1.name, & &1.module)
      |> Enum.filter(fn {_name, modules} -> match?([_, _ | _], modules) end)

    case duplicates do
      [] ->
        :ok

      duplicates ->
        details =
          Enum.map_join(duplicates, ", ", fn {name, modules} ->
            "#{name} (#{Enum.map_join(modules, ", ", &inspect/1)})"
          end)

        Mix.raise("tool names must be unique across modules: #{details}")
    end
  end

  defp render(modules, "openai", strict?, _specs),
    do: Enum.flat_map(modules, &ToolCall.emit(&1, :openai, strict: strict?))

  defp render(modules, "anthropic", _strict?, _specs),
    do: Enum.flat_map(modules, &ToolCall.emit(&1, :anthropic))

  defp render(_modules, "mcp", _strict?, specs) do
    %{
      "tools" =>
        Enum.map(specs, fn spec ->
          %{
            "name" => spec.name,
            "description" => spec.description,
            "inputSchema" => spec.parameters
          }
        end)
    }
  end

  # TODO: use JSON.format/1 once Elixir's JSON ships a pretty printer, which
  # would drop the OTP 27.1 requirement.
  defp encode(term) do
    unless Code.ensure_loaded?(:json) and function_exported?(:json, :format, 1) do
      Mix.raise("mix tool_call.export requires Erlang/OTP 27.1+ (json:format/1)")
    end

    term
    |> otp_json()
    |> :json.format()
    |> IO.iodata_to_binary()
  end

  # OTP's json turns every atom into a string, including the Elixir atom nil;
  # JSON null is the atom null.
  defp otp_json(term) when is_map(term),
    do: Map.new(term, fn {key, value} -> {key, otp_json(value)} end)

  defp otp_json(term) when is_list(term), do: Enum.map(term, &otp_json/1)
  defp otp_json(nil), do: :null
  defp otp_json(term), do: term

  defp write(json, nil), do: IO.write(json)

  defp write(json, path) do
    File.mkdir_p!(Path.dirname(path))
    tmp = "#{path}.tmp.#{System.unique_integer([:positive])}"

    try do
      File.write!(tmp, json)
      replace(tmp, path)
    rescue
      exception ->
        File.rm(tmp)
        reraise exception, __STACKTRACE__
    end

    Mix.shell().info("Wrote #{Path.relative_to_cwd(path)}")
  end

  defp replace(tmp, path) do
    File.rename!(tmp, path)
  rescue
    exception in File.RenameError ->
      if exception.reason == :eexist do
        File.rm!(path)
        File.rename!(tmp, path)
      else
        reraise exception, __STACKTRACE__
      end
  end
end
