defmodule Typsty.MixProject do
  use Mix.Project

  @source_url "https://github.com/akoutmos/typsty"

  def project do
    [
      app: :typsty,
      version: project_version(),
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      name: "Typsty",
      source_url: @source_url,
      homepage_url: @source_url,
      description:
        "Render Typst documents to PDF, PNG and SVG with Elixir data, from templates checked at compile time",
      start_permanent: Mix.env() == :prod,
      # Tests implement Typsty.Encoder for their own structs
      consolidate_protocols: Mix.env() != :test,
      test_coverage: [tool: ExCoveralls],
      package: package(),
      deps: deps(),
      docs: docs(),
      dialyzer: dialyzer()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.github": :test
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp package do
    [
      name: "typsty",
      # The NIF and the worker are downloaded precompiled, and built from the native/ workspace
      # when TYPSTY_BUILD is set. The README's images are only needed by the docs, which get
      # them through :assets.
      files:
        ~w(lib native/Cargo.toml native/Cargo.lock native/.cargo) ++
          for(
            crate <- ~w(typsty_core typsty_nif typsty_worker),
            path <- ~w(Cargo.toml src),
            do: "native/#{crate}/#{path}"
          ) ++
          ~w(checksum-*.exs mix.exs .formatter.exs README.md LICENSE CHANGELOG.md VERSION),
      exclude_patterns: [~r/\.DS_Store$/],
      licenses: ["MIT"],
      maintainers: ["Alex Koutmos"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/master/CHANGELOG.md",
        "Sponsor" => "https://github.com/sponsors/akoutmos"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      # Releases are tagged with their version, such as 0.1.0
      source_ref: project_version(),
      # The README references its images as images/...
      assets: %{"images" => "images"},
      extras: ["README.md", "CHANGELOG.md"],
      groups_for_modules: [
        Documents: [Typsty, Typsty.Template, Typsty.Pool],
        Data: [Typsty.Encoder],
        Errors: [Typsty.RenderError, Typsty.SyntaxError, Typsty.Diagnostic],
        Tooling: [Typsty.Formatter, Typsty.Telemetry, Mix.Tasks.Typsty.Packages.Get]
      ]
    ]
  end

  defp dialyzer do
    [
      # The formatter plugin and the packages task use Mix, and the task downloads with :httpc
      plt_add_apps: [:mix, :inets, :ssl, :public_key, :crypto],
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
    ]
  end

  defp deps do
    [
      # Production deps
      {:rustler_precompiled, "~> 0.10"},
      {:rustler, "~> 0.38", optional: true},
      {:telemetry, "~> 1.0"},
      {:nimble_pool, "~> 1.1"},
      {:nimble_options, "~> 1.1"},

      # Development deps
      {:decimal, "~> 2.0 or ~> 3.0", only: [:dev, :test]},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: [:test, :dev], runtime: false},
      {:doctor, "~> 0.23", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false}
    ]
  end

  defp project_version do
    __DIR__
    |> Path.join("VERSION")
    |> File.read!()
    |> String.trim()
  end
end
