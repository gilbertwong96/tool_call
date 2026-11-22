defmodule ToolCall.SchemaProjectionTest do
  use ExUnit.Case, async: true

  alias ToolCall.Schema.Gemini

  describe "to_gemini/2" do
    test "rewrites the shared JSON Schema into Gemini's OpenAPI subset" do
      schema = %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{
          "kind" => %{"type" => ["string", "null"]},
          "choice" => %{"anyOf" => [%{"type" => "string"}, %{"type" => "null"}]},
          "color" => %{"type" => "string", "enum" => ["red", "blue"]},
          "mixed" => %{"enum" => ["red", 1]},
          "tuple" => %{
            "type" => "array",
            "prefixItems" => [%{"type" => "integer"}],
            "minItems" => 1,
            "maxItems" => 1
          },
          "list" => %{"type" => "array"}
        }
      }

      assert %{
               "type" => "OBJECT",
               "properties" => %{
                 "kind" => %{"type" => "STRING", "nullable" => true},
                 "choice" => %{"anyOf" => [%{"type" => "STRING"}], "nullable" => true},
                 "color" => %{"type" => "STRING", "enum" => ["red", "blue"], "format" => "enum"},
                 "mixed" => %{},
                 "tuple" => %{
                   "type" => "ARRAY",
                   "items" => %{},
                   "minItems" => 1,
                   "maxItems" => 1
                 },
                 "list" => %{"type" => "ARRAY", "items" => %{}}
               }
             } = Gemini.to_gemini(schema)
    end

    test "raises for local definitions by default" do
      schema = %{
        "$defs" => %{"name" => %{"type" => "string"}},
        "$ref" => "#/$defs/name"
      }

      assert_raise ArgumentError, ~r/cannot express `\$ref`\/`\$defs`/, fn ->
        Gemini.to_gemini(schema)
      end
    end

    test "inlines local definitions" do
      schema = %{
        "type" => "object",
        "properties" => %{"node" => %{"$ref" => "#/$defs/node"}},
        "$defs" => %{
          "node" => %{
            "type" => "object",
            "properties" => %{"name" => %{"type" => "string"}}
          }
        }
      }

      assert %{
               "type" => "OBJECT",
               "properties" => %{
                 "node" => %{
                   "type" => "OBJECT",
                   "properties" => %{"name" => %{"type" => "STRING"}}
                 }
               }
             } = Gemini.to_gemini(schema, on_ref: :inline)
    end

    test "refuses to inline a recursive definition" do
      schema = %{
        "type" => "object",
        "properties" => %{"next" => %{"$ref" => "#/$defs/node"}},
        "$defs" => %{
          "node" => %{
            "type" => "object",
            "properties" => %{"next" => %{"$ref" => "#/$defs/node"}}
          }
        }
      }

      assert_raise ArgumentError, ~r/recursive/, fn ->
        Gemini.to_gemini(schema, on_ref: :inline)
      end
    end

    test "drops local definitions and references" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "node" => %{"$ref" => "#/$defs/node", "description" => "kept"}
        },
        "$defs" => %{"node" => %{"type" => "string"}}
      }

      assert %{
               "type" => "OBJECT",
               "properties" => %{"node" => %{"description" => "kept"}}
             } = Gemini.to_gemini(schema, on_ref: :drop)
    end

    test "keeps the tool name in the default reference error" do
      schema = %{"type" => "object", "$defs" => %{"node" => %{"type" => "string"}}}

      assert_raise ArgumentError, ~r/"walk" uses a recursive type/, fn ->
        Gemini.to_gemini(schema, name: "walk")
      end
    end

    test "requires an object schema at the root" do
      for schema <- [%{"type" => "string"}, %{}] do
        error = assert_raise ArgumentError, fn -> Gemini.to_gemini(schema) end
        assert Exception.message(error) =~ "object schema"
      end
    end

    test "rejects multi-type arrays instead of widening them" do
      schema = %{
        "type" => "object",
        "properties" => %{"value" => %{"type" => ["string", "integer"]}}
      }

      error = assert_raise ArgumentError, fn -> Gemini.to_gemini(schema) end
      assert Exception.message(error) =~ "multi-type"
    end

    test "rejects null-only schemas instead of emitting NULL" do
      for schema <- [
            %{
              "type" => "object",
              "properties" => %{"value" => %{"type" => "null"}}
            },
            %{
              "type" => "object",
              "properties" => %{"value" => %{"type" => ["null"]}}
            },
            %{
              "type" => "object",
              "properties" => %{"value" => %{"anyOf" => [%{"type" => "null"}]}}
            }
          ] do
        error = assert_raise ArgumentError, fn -> Gemini.to_gemini(schema) end
        assert Exception.message(error) =~ "null-only"
      end
    end

    test "rejects JSON Schema keywords Gemini cannot express" do
      for {keyword, value} <- [
            {"oneOf", []},
            {"const", 1},
            {"allOf", []},
            {"not", %{}}
          ] do
        schema = %{
          "type" => "object",
          "properties" => %{"value" => %{keyword => value}}
        }

        error = assert_raise ArgumentError, fn -> Gemini.to_gemini(schema) end
        assert Exception.message(error) =~ "`#{keyword}`"
      end
    end

    test "rejects an unknown reference policy" do
      assert_raise ArgumentError, ~r/on_ref must be :raise, :drop or :inline/, fn ->
        Gemini.to_gemini(%{}, on_ref: :bogus)
      end
    end
  end
end
