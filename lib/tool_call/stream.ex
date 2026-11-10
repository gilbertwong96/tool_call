defmodule ToolCall.Stream do
  @moduledoc """
  Aggregates provider streaming deltas into complete tool calls.

  `run/3` takes a complete call: a tool name and a decoded arguments map. While a
  response streams, the provider sends that call in pieces. This module folds
  the provider's chunks and answers `{:ok, calls}`, where each call is
  `%{id: id | nil, name: name, arguments: arguments_map}` and is ready for
  `ToolCall.run/3`.

      chunks
      |> ToolCall.Stream.aggregate(:openai)
      #=> {:ok, [%{id: "call_1", name: "get_weather", arguments: %{"city" => "Oslo"}}]}

  or, chunk by chunk:

      acc = ToolCall.Stream.new(:anthropic)
      acc = Enum.reduce(chunks, acc, &ToolCall.Stream.feed(&2, &1))
      ToolCall.Stream.finish(acc)

  Supported streams:

    * `:openai` - Chat Completions `delta.tool_calls` fragments, keyed by
      `index`. Only the first choice is aggregated; stream with `n = 1` or
      split choices yourself.
    * `:anthropic` - Messages `content_block_start` for a `tool_use` block plus
      `input_json_delta` fragments (and the block's initial `input` when there
      are none).
    * `:gemini` - the first candidate's `streamGenerateContent` parts with a
      complete `functionCall`. Gemini has no call id, so `id` is `nil`.

  The concatenated JSON is decoded with the standard `JSON` module, so
  `arguments` is a map. Invalid JSON is `{:error, {:invalid_stream_arguments, {id,
  name, json}}}`; a call that never receives a name is
  `{:error, {:missing_name, id}}`.
  """

  @type provider :: :openai | :anthropic | :gemini

  @type call :: %{
          id: String.t() | nil,
          name: String.t(),
          arguments: %{optional(String.t()) => term()}
        }

  @type error ::
          {:missing_name, String.t() | nil}
          | {:invalid_stream_arguments, {String.t() | nil, String.t() | nil, term()}}

  @type t :: %__MODULE__{
          provider: provider(),
          calls: %{term() => map()},
          order: [term()],
          next: non_neg_integer()
        }

  defstruct [:provider, calls: %{}, order: [], next: 0]

  @doc """
  Starts an accumulator for `provider` (`:openai`, `:anthropic` or `:gemini`).
  """
  @spec new(provider()) :: t()
  def new(provider) when provider in [:openai, :anthropic, :gemini] do
    %__MODULE__{provider: provider}
  end

  def new(other) do
    raise ArgumentError,
          "unsupported stream provider #{inspect(other)}; expected :openai, :anthropic or :gemini"
  end

  @doc """
  Folds one streamed chunk into the accumulator.

  Chunks that carry no tool-call data (text deltas, message metadata) are
  ignored.
  """
  @spec feed(t(), map()) :: t()
  def feed(%__MODULE__{provider: :openai} = acc, chunk) when is_map(chunk),
    do: openai(acc, chunk)

  def feed(%__MODULE__{provider: :anthropic} = acc, chunk) when is_map(chunk),
    do: anthropic(acc, chunk)

  def feed(%__MODULE__{provider: :gemini} = acc, chunk) when is_map(chunk),
    do: gemini(acc, chunk)

  @doc """
  Returns the completed calls in their provider order.

  A call with a missing name or unparsable arguments answers `{:error, reason}`
  and drops the whole stream result.
  """
  @spec finish(t()) :: {:ok, [call()]} | {:error, error()}
  def finish(%__MODULE__{} = acc) do
    acc
    |> calls_in_order()
    |> Enum.reduce_while({:ok, []}, fn call, {:ok, calls} ->
      case build_call(call) do
        {:ok, built} -> {:cont, {:ok, [built | calls]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, calls} -> {:ok, Enum.reverse(calls)}
      error -> error
    end
  end

  @doc """
  Aggregates an enumerable of chunks in one pass.
  """
  @spec aggregate(Enumerable.t(), provider()) :: {:ok, [call()]} | {:error, error()}
  def aggregate(chunks, provider) do
    chunks
    |> Enum.reduce(new(provider), &feed(&2, &1))
    |> finish()
  end

  defp openai(acc, %{"choices" => choices}) when is_list(choices) do
    case List.first(choices) do
      %{"delta" => %{"tool_calls" => tool_calls}} when is_list(tool_calls) ->
        Enum.reduce(tool_calls, acc, fn tool_call, acc ->
          function = tool_call["function"] || %{}

          update(acc, {:openai, tool_call["index"] || 0},
            id: tool_call["id"],
            name: function["name"],
            part: function["arguments"]
          )
        end)

      _other ->
        acc
    end
  end

  defp openai(acc, _chunk), do: acc

  defp anthropic(
         acc,
         %{
           "type" => "content_block_start",
           "index" => index,
           "content_block" => %{"type" => "tool_use"} = block
         }
       ) do
    update(acc, {:anthropic, index},
      id: block["id"],
      name: block["name"],
      input: block["input"]
    )
  end

  defp anthropic(
         acc,
         %{
           "type" => "content_block_delta",
           "index" => index,
           "delta" => %{"type" => "input_json_delta", "partial_json" => json}
         }
       ) do
    update(acc, {:anthropic, index}, part: json)
  end

  defp anthropic(acc, _chunk), do: acc

  defp gemini(acc, %{"candidates" => [candidate | _rest]}) when is_map(candidate) do
    candidate
    |> get_in(["content", "parts"])
    |> List.wrap()
    |> Enum.reduce(acc, fn
      %{"functionCall" => %{"name" => name} = call}, acc ->
        complete(acc, name, call["args"] || %{})

      _part, acc ->
        acc
    end)
  end

  defp gemini(acc, _chunk), do: acc

  defp complete(acc, name, args) do
    key = {:gemini, acc.next}

    call = %{id: nil, name: name, parts: [], input: nil, args: args}

    %{
      acc
      | calls: Map.put(acc.calls, key, call),
        order: [key | acc.order],
        next: acc.next + 1
    }
  end

  defp update(acc, key, opts) do
    existing = Map.get(acc.calls, key)

    call =
      case existing do
        nil ->
          %{
            id: opts[:id],
            name: opts[:name],
            parts: part_list(opts[:part]),
            input: opts[:input],
            args: nil
          }

        call ->
          %{
            call
            | id: call.id || opts[:id],
              name: call.name || opts[:name],
              parts: add_part(call.parts, opts[:part]),
              input: call.input || opts[:input]
          }
      end

    %{acc | calls: Map.put(acc.calls, key, call), order: add_order(acc.order, key, existing)}
  end

  defp part_list(part) when is_binary(part), do: [part]
  defp part_list(_part), do: []

  defp add_part(parts, part) when is_binary(part), do: [part | parts]
  defp add_part(parts, _part), do: parts

  defp add_order(order, key, nil), do: [key | order]
  defp add_order(order, _key, _existing), do: order

  defp calls_in_order(acc) do
    acc.order
    |> Enum.sort_by(fn {_provider, index} -> index end)
    |> Enum.map(&Map.fetch!(acc.calls, &1))
  end

  defp build_call(%{args: args} = call) when not is_nil(args) do
    if is_map(args) do
      {:ok, %{id: call.id, name: call.name, arguments: args}}
    else
      {:error, {:invalid_stream_arguments, {call.id, call.name, args}}}
    end
  end

  defp build_call(%{name: nil} = call), do: {:error, {:missing_name, call.id}}

  defp build_call(call) do
    json = call.parts |> Enum.reverse() |> IO.iodata_to_binary()

    cond do
      json == "" and is_map(call.input) ->
        {:ok, %{id: call.id, name: call.name, arguments: call.input}}

      json == "" ->
        {:ok, %{id: call.id, name: call.name, arguments: %{}}}

      true ->
        decode(call, json)
    end
  end

  defp decode(call, json) do
    case JSON.decode(json) do
      {:ok, arguments} when is_map(arguments) ->
        {:ok, %{id: call.id, name: call.name, arguments: arguments}}

      _other ->
        {:error, {:invalid_stream_arguments, {call.id, call.name, json}}}
    end
  end
end
