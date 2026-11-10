defmodule ToolCall.StreamTest do
  use ExUnit.Case, async: true

  alias ToolCall.Stream

  defp openai(chunks) do
    chunks =
      for chunk <- chunks do
        %{"choices" => [%{"index" => 0, "delta" => chunk}]}
      end

    Stream.aggregate(chunks, :openai)
  end

  describe "OpenAI" do
    test "concatenates indexed tool_call fragments" do
      assert {:ok, [call]} =
               openai([
                 %{
                   "tool_calls" => [
                     %{
                       "index" => 0,
                       "id" => "call_1",
                       "type" => "function",
                       "function" => %{"name" => "get_weather", "arguments" => ""}
                     }
                   ]
                 },
                 %{
                   "tool_calls" => [
                     %{"index" => 0, "function" => %{"arguments" => "{\"city\":\"Os"}}
                   ]
                 },
                 %{"tool_calls" => [%{"index" => 0, "function" => %{"arguments" => "lo\"}"}}]},
                 %{"content" => "ignored"}
               ])

      assert call == %{id: "call_1", name: "get_weather", arguments: %{"city" => "Oslo"}}
    end

    test "orders multiple calls by index" do
      assert {:ok, [first, second]} =
               openai([
                 %{
                   "tool_calls" => [
                     %{
                       "index" => 1,
                       "id" => "call_b",
                       "function" => %{"name" => "b", "arguments" => "{}"}
                     },
                     %{
                       "index" => 0,
                       "id" => "call_a",
                       "function" => %{"name" => "a", "arguments" => ""}
                     }
                   ]
                 },
                 %{"tool_calls" => [%{"index" => 0, "function" => %{"arguments" => "{\"x\":1}"}}]}
               ])

      assert first == %{id: "call_a", name: "a", arguments: %{"x" => 1}}
      assert second == %{id: "call_b", name: "b", arguments: %{}}
    end

    test "an empty arguments string is an empty map" do
      assert {:ok, [%{arguments: %{}}]} =
               openai([
                 %{
                   "tool_calls" => [
                     %{
                       "index" => 0,
                       "id" => "call_1",
                       "function" => %{"name" => "ping", "arguments" => ""}
                     }
                   ]
                 }
               ])
    end

    test "reports invalid JSON" do
      assert {:error, {:invalid_stream_arguments, {"call_1", "go", "{"}}} =
               openai([
                 %{
                   "tool_calls" => [
                     %{
                       "index" => 0,
                       "id" => "call_1",
                       "function" => %{"name" => "go", "arguments" => "{"}
                     }
                   ]
                 }
               ])
    end

    test "reports a call without a name" do
      assert {:error, {:missing_name, "call_1"}} =
               openai([
                 %{
                   "tool_calls" => [
                     %{"index" => 0, "id" => "call_1", "function" => %{"arguments" => "{}"}}
                   ]
                 }
               ])
    end

    test "feed/2 and finish/1 match aggregate/2" do
      chunks = [
        %{
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [
                  %{
                    "index" => 0,
                    "id" => "c",
                    "function" => %{"name" => "go", "arguments" => "{}"}
                  }
                ]
              }
            }
          ]
        }
      ]

      acc = Enum.reduce(chunks, Stream.new(:openai), &Stream.feed(&2, &1))

      assert Stream.finish(acc) == Stream.aggregate(chunks, :openai)
    end
  end

  describe "Anthropic" do
    test "concatenates input_json_delta fragments" do
      chunks = [
        %{"type" => "message_start", "message" => %{}},
        %{
          "type" => "content_block_start",
          "index" => 1,
          "content_block" => %{
            "type" => "tool_use",
            "id" => "toolu_1",
            "name" => "get_weather",
            "input" => %{}
          }
        },
        %{
          "type" => "content_block_delta",
          "index" => 1,
          "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"city\":\"Os"}
        },
        %{
          "type" => "content_block_delta",
          "index" => 1,
          "delta" => %{"type" => "input_json_delta", "partial_json" => "lo\"}"}
        },
        %{"type" => "content_block_stop", "index" => 1},
        %{"type" => "message_delta", "delta" => %{"stop_reason" => "tool_use"}}
      ]

      assert {:ok, [call]} = Stream.aggregate(chunks, :anthropic)
      assert call == %{id: "toolu_1", name: "get_weather", arguments: %{"city" => "Oslo"}}
    end

    test "a tool with no fragments uses the start input" do
      chunks = [
        %{
          "type" => "content_block_start",
          "index" => 0,
          "content_block" => %{
            "type" => "tool_use",
            "id" => "toolu_1",
            "name" => "ping",
            "input" => %{}
          }
        }
      ]

      assert {:ok, [%{arguments: %{}}]} = Stream.aggregate(chunks, :anthropic)
    end

    test "ignores text and message deltas" do
      chunks = [
        %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "text_delta", "text" => "hi"}
        },
        %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}}
      ]

      assert {:ok, []} = Stream.aggregate(chunks, :anthropic)
    end
  end

  describe "Gemini" do
    test "only reads the first candidate" do
      chunks = [
        %{
          "candidates" => [
            %{"content" => %{"parts" => [%{"functionCall" => %{"name" => "a"}}]}},
            %{"content" => %{"parts" => [%{"functionCall" => %{"name" => "b"}}]}}
          ]
        }
      ]

      assert {:ok, [%{name: "a"}]} = Stream.aggregate(chunks, :gemini)
    end

    test "collects complete functionCall parts" do
      chunks = [
        %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "thinking"}]}}]},
        %{
          "candidates" => [
            %{
              "content" => %{
                "parts" => [
                  %{"functionCall" => %{"name" => "get_weather", "args" => %{"city" => "Oslo"}}},
                  %{"functionCall" => %{"name" => "ping"}}
                ]
              }
            }
          ]
        }
      ]

      assert {:ok, [weather, ping]} = Stream.aggregate(chunks, :gemini)
      assert weather == %{id: nil, name: "get_weather", arguments: %{"city" => "Oslo"}}
      assert ping == %{id: nil, name: "ping", arguments: %{}}
    end
  end

  test "an empty stream finishes with no calls" do
    assert {:ok, []} = Stream.aggregate([], :openai)
  end

  test "rejects an unsupported provider" do
    assert_raise ArgumentError, ~r/unsupported stream provider/, fn ->
      Stream.new(:bogus)
    end
  end
end
