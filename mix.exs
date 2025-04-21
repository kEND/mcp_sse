defmodule MCPSse.MixProject do
  use Mix.Project

  @version "0.1.6"
  @source_url "https://github.com/kend/mcp_sse"

  def project do
    [
      app: :mcp_sse,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),

      # Hex
      description: "Server-Sent Events (SSE) implementation of the Model Context Protocol (MCP)",
      package: package(),

      # Docs
      name: "MCP SSE",
      docs: docs(),
      source_url: @source_url
    ]
  end

  defp package do
    [
      maintainers: ["Ken Barker"],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Model Context Protocol" => "https://modelcontextprotocol.io/introduction"
      },
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_url: @source_url,
      source_ref: "v#{@version}",
      formatters: ["html"]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {MCP.SSE, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.14"},

      # Documentation
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},

      # pre-commit
      {:git_hooks, "~> 0.8.0", only: [:dev], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},

      # Testing
      {:plug_cowboy, "~> 2.6", only: :test},
      {:ex_json_schema, "~> 0.10.2", only: :test}
    ]
  end

  # Specify which paths to compile per environment
  defp elixirc_paths(:dev), do: ["lib", "dev"]
  defp elixirc_paths(:test), do: ["lib", "test"]
  defp elixirc_paths(_), do: ["lib"]
end
