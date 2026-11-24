defmodule Mix.Tasks.Typsty.Packages.Get do
  @shortdoc "Downloads Typst packages from Typst Universe"

  @moduledoc """
  Downloads [Typst packages](https://typst.app/universe) into your project, so that
  templates can import them.

  ```shell
  mix typsty.packages.get @preview/cetz:0.4.2 @preview/tablex:0.0.9
  ```

  Packages are saved in `priv/typst/packages`, laid out as `namespace/name/version` like
  Typst's own package directories, so they ship with your releases. Point the
  `:package_paths` option at that directory, in `config/runtime.exs`:

  ```elixir
  config :typsty, package_paths: [Application.app_dir(:my_app, "priv/typst/packages")]
  ```

  Templates then import them as usual:

  ```typst
  #import "@preview/cetz:0.4.2": canvas, draw
  ```

  A package given without a version (`@preview/cetz`) gets its latest version that works
  with the version of Typst that Typsty uses. Packages that a package imports are fetched
  too. Packages already in the directory aren't downloaded again, since Typst Universe
  never changes a published version.

  ## Configured packages

  Without arguments, the task fetches the packages listed in your config, which keeps the
  list in your repository and works well in CI and Docker builds:

  ```elixir
  # config/config.exs
  config :typsty, packages: ["@preview/cetz:0.4.2", "@preview/tablex:0.0.9"]
  ```

  ```shell
  mix typsty.packages.get
  ```

  ## Options

  - `--path` - the directory to save packages in. Defaults to `priv/typst/packages`.
  - `--force` - download packages again, even if they're already in the directory.

  Downloads go through the `HTTPS_PROXY` or `HTTP_PROXY` proxy when one is set.
  """

  use Mix.Task

  @default_path "priv/typst/packages"

  @impl Mix.Task
  def run(args) do
    {opts, specs} = OptionParser.parse!(args, strict: [path: :string, force: :boolean])

    specs =
      case specs do
        [] -> configured_packages()
        specs -> specs
      end

    path = Keyword.get(opts, :path, @default_path)

    results =
      Typsty.Packages.get(specs, path,
        force: Keyword.get(opts, :force, false),
        report: fn message -> Mix.shell().info(message) end
      )

    fetched = Enum.count(results, &match?({_package, :fetched, _imported_by}, &1))
    Mix.shell().info("\n#{fetched} of #{length(results)} packages downloaded into #{path}")
  end

  defp configured_packages do
    case Application.get_env(:typsty, :packages, []) do
      [_ | _] = packages ->
        packages

      [] ->
        Mix.raise(
          "no packages to fetch. Pass them as arguments (mix typsty.packages.get @preview/cetz:0.4.2), " <>
            "or list them in your config: config :typsty, packages: [\"@preview/cetz:0.4.2\"]"
        )

      other ->
        Mix.raise("the :packages config must be a list of packages, got: #{inspect(other)}")
    end
  end
end
