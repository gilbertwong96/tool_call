defmodule ToolCall.DocTest do
  use ExUnit.Case, async: true

  alias ToolCall.Doc

  test "takes the first paragraph as the description" do
    doc = """
    Get the forecast.

    More detail that the model does not need.

    ## Parameters
      * `city` - city name
    """

    assert %{description: "Get the forecast."} = Doc.parse(doc)
  end

  test "reads bullets under a Parameters heading" do
    doc = """
    Search.

    ## Parameters
      * `query` - free text
      * `limit` - page size
    """

    assert %{params: %{"query" => "free text", "limit" => "page size"}} = Doc.parse(doc)
  end

  test "ignores nested bullets, which are not parameters" do
    doc = """
    Search.

    ## Parameters
      * `a` - x
        * `b` - y
    """

    assert %{params: %{"a" => "x"}} = Doc.parse(doc)
  end

  test "joins indented continuation lines into the bullet" do
    doc = """
    Search.

    ## Parameters
      * `query` - free text,
        matched case-insensitively
      * `limit` - page size
    """

    assert %{
             params: %{
               "query" => "free text, matched case-insensitively",
               "limit" => "page size"
             }
           } = Doc.parse(doc)
  end

  test "accepts alternative headings and bullet styles" do
    doc = """
    Search.

    ## Options
    - `query`: free text
    """

    assert %{params: %{"query" => "free text"}} = Doc.parse(doc)
  end

  test "accepts a ## Params heading" do
    doc = """
    Search.

    ## Params
      * `query` - free text
    """

    assert %{params: %{"query" => "free text"}} = Doc.parse(doc)
  end

  test "drops a leading markdown heading from the description" do
    doc = """
    # Get the weather
    City forecast.
    """

    assert %{description: "Get the weather\nCity forecast."} = Doc.parse(doc)
  end

  test "stops at the next heading" do
    doc = """
    Search.

    ## Parameters
      * `query` - free text

    ## Examples
      * `query` - not a parameter
    """

    assert %{params: %{"query" => "free text"}} = Doc.parse(doc)
  end

  test "ignores bullets that do not name a parameter" do
    doc = """
    Search.

    ## Parameters
      no bullets here
      * `query` (string) - typed bullets are not supported
    """

    assert %{params: %{}} = Doc.parse(doc)
  end

  test "a document without a blank line still yields a description" do
    assert %{description: "One line."} = Doc.parse("One line.")
  end

  test "handles missing and hidden docs" do
    assert %{description: nil, params: %{}} = Doc.parse(nil)
    assert %{description: nil, params: %{}} = Doc.parse(false)
  end
end
