defmodule ToolCall.Generated do
  @moduledoc false
  # Phase-one modules call these helpers from their generated `__tools__/0` and
  # `__schemas__/0`. The phase-two companion carries the typedoc-enriched
  # literals and the compile-generation token. The token is not a hash of the
  # enriched content: it changes on every phase-one compile, so a typedoc-only
  # change still invalidates a stale or partially written companion and falls
  # back to the phase-one data. The token combines wall-clock nanoseconds with
  # a VM-local counter, so it is unique across VM restarts (each `mix compile`
  # starts a fresh VM), not merely unique within one VM.
  #
  # `create/5` and `remove/2` own the companion lifecycle: `:nofile` modules
  # keep the companion in memory, while source-file modules persist it under
  # `Mix.Project.compile_path/0` so releases can load it.

  alias ToolCall.IR.Tool

  @generation_shift 64

  @spec companion(module()) :: module()
  def companion(module), do: Module.concat(module, "__ToolCall__")

  @spec generation() :: pos_integer()
  def generation do
    timestamp = System.system_time(:nanosecond)
    unique = :erlang.unique_integer([:positive])
    Bitwise.bsl(timestamp, @generation_shift) + unique
  end

  @spec tools(module(), pos_integer(), [Tool.t()]) :: [Tool.t()]
  def tools(companion, generation, fallback) do
    if current?(companion, :__tools__, generation), do: companion.__tools__(), else: fallback
  end

  @spec schemas(module(), pos_integer(), map()) :: map()
  def schemas(companion, generation, fallback) do
    if current?(companion, :__schemas__, generation), do: companion.__schemas__(), else: fallback
  end

  @spec create(Macro.Env.t(), module(), [Tool.t()], map(), pos_integer()) :: :ok | :error
  def create(env, companion, tools, schemas, generation) do
    remove(env, companion)

    case beam_path(env, companion) do
      :memory ->
        create_module(env, companion, tools, schemas, generation)
        :ok

      {:ok, path} ->
        {:module, _companion, binary, _term} =
          create_module(env, companion, tools, schemas, generation)

        case write_atomic(path, binary) do
          :ok ->
            :ok

          {:error, reason} ->
            purge(companion)
            warn_write_failure(env, companion, reason)
            :error
        end

      :error ->
        warn_unavailable(env, companion)
        :error
    end
  end

  @spec remove(Macro.Env.t(), module()) :: :ok
  def remove(env, companion) do
    purge(companion)
    delete_beam(env, companion)
    :ok
  end

  defp create_module(env, companion, tools, schemas, generation) do
    quoted =
      quote do
        @moduledoc false
        def __tools__, do: unquote(Macro.escape(tools))
        def __schemas__, do: unquote(Macro.escape(schemas))
        def __generation__, do: unquote(generation)
      end

    Module.create(companion, quoted, file: env.file, line: env.line)
  end

  defp beam_path(%{file: "nofile"}, _companion), do: :memory

  defp beam_path(_env, companion) do
    case compile_path() do
      {:ok, path} -> {:ok, Path.join(path, beam_name(companion))}
      :error -> :error
    end
  end

  defp delete_beam(%{file: "nofile"}, _companion), do: :ok

  defp delete_beam(_env, companion) do
    case compile_path() do
      {:ok, path} -> File.rm(Path.join(path, beam_name(companion)))
      :error -> :ok
    end
  end

  defp write_atomic(path, binary) do
    temporary = "#{path}.#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temporary, binary),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, reason}
    end
  end

  defp beam_name(companion), do: Atom.to_string(companion) <> ".beam"

  defp compile_path do
    if Code.ensure_loaded?(Mix.Project) and Mix.Project.get() do
      {:ok, Mix.Project.compile_path()}
    else
      :error
    end
  rescue
    _exception -> :error
  end

  defp purge(companion) do
    :code.purge(companion)
    :code.delete(companion)
    :ok
  end

  defp warn_write_failure(env, companion, reason) do
    IO.warn(
      "#{inspect(companion)}: could not write the typedoc companion beam " <>
        "(#{:file.format_error(reason)}); using phase-one descriptions",
      file: env.file,
      line: env.line
    )
  end

  defp warn_unavailable(env, companion) do
    IO.warn(
      "#{inspect(companion)}: Mix.Project.compile_path/0 is unavailable; " <>
        "typedoc descriptions are skipped for this build",
      file: env.file,
      line: env.line
    )
  end

  defp current?(companion, function, generation) do
    loaded? = Code.ensure_loaded?(companion)
    exported? = function_exported?(companion, function, 0)
    stamped? = function_exported?(companion, :__generation__, 0)

    if loaded? and exported? and stamped? do
      companion.__generation__() == generation
    else
      false
    end
  end
end
