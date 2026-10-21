defmodule DelivestAgent.MixProject do
  use Mix.Project

  def project do
    [
      app: :delivest_agent,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [delivest_agent: [include_executables_for: [:unix]]]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl],
      mod: {DelivestAgent.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:slipstream, "~> 1.2"},
      {:jason, "~> 1.4"}
    ]
  end
end
