defmodule ToolCallBench.MixProject do
  use Mix.Project

  def project do
    [
      app: :tool_call_bench,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: false,
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    [
      {:tool_call, path: ".."},
      {:req_llm, "~> 1.30"},
      {:benchee, "~> 1.4"}
    ]
  end
end
