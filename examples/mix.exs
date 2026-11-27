defmodule TypstyExamples.MixProject do
  use Mix.Project

  def project do
    [
      app: :typsty_examples,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {TypstyExamples.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:typsty, path: ".."},
      # Typsty is built from source when it is a development version, as it is here
      {:rustler, ">= 0.0.0", optional: true},
      {:decimal, "~> 3.2"}
    ]
  end
end
