defmodule ToolCall.MixProject do
  use Mix.Project

  @version "0.1.0-dev"

  def project do
    [
      app: :tool_call,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "ToolCall",
      description:
        "Derive LLM tool-call schemas from Elixir @spec and @doc, with a runtime dispatcher.",
      package: package(),
      docs: [
        main: "readme",
        extras: [
          "README.md",
          "CHANGELOG.md",
          "docs/usage.md",
          "docs/design.md",
          "docs/roadmap.md",
          "docs/pitfalls.md",
          "docs/number-handling.md"
        ]
      ],
      dialyzer: [plt_add_apps: [:mix, :ex_unit]],
      test_coverage: [tool: ExCoveralls],
      aliases: aliases()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  def cli do
    [
      preferred_envs: [
        ci: :test,
        coveralls: :test,
        "coveralls.html": :test,
        "coveralls.json": :test,
        "coveralls.cobertura": :test
      ]
    ]
  end

  defp deps do
    [
      {:excoveralls, "~> 0.18", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:spec_lint, "~> 0.1", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.0", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.0", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.0", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      files: ~w(lib docs README.md CHANGELOG.md LICENSE mix.exs .formatter.exs),
      links: %{}
    ]
  end

  defp aliases() do
    [
      ci: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "test",
        "spec_lint --warnings-as-errors",
        "credo --strict",
        "dialyzer",
        "ex_dna --max-clones 0",
        "reach.check --arch --smells"
      ]
    ]
  end
end
