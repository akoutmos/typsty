defmodule Mix.Tasks.Typsty.Packages.Get do
  @shortdoc "Downloads Typst packages from Typst Universe"

  @moduledoc """
  Downloads [Typst packages](https://typst.app/universe) into your project, so that
  templates can import them.

  ```shell
  mix typsty.packages.get @preview/cetz:0.4.2 @preview/oxifmt:1.0.0
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
  never changes a published version. Versions you no longer use stay in the directory until
  you delete them.

  ## Configured packages

  Without arguments, the task fetches the packages listed in your config, which keeps the
  list in your repository and works well in CI and Docker builds:

  ```elixir
  # config/config.exs
  config :typsty, packages: ["@preview/cetz:0.4.2", "@preview/oxifmt:1.0.0"]
  ```

  ```shell
  mix typsty.packages.get
  ```

  Packages in the config must have a version, since templates import exact versions: an
  unpinned package would change whenever a new version came out. In a Docker build, run the
  task in the build stage, before `mix release`; it needs the network.

  ## Options

  - `--path` - the directory to save packages in. Defaults to `priv/typst/packages`, in the
    current project. In an umbrella project, run the task in the app that renders, or give
    a path.
  - `--force` - download packages again, even if they're already in the directory.

  Downloads go through the proxy in `HTTPS_PROXY` (or `HTTP_PROXY`) when one is set,
  except for the hosts in `NO_PROXY`.
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

    path = Keyword.get_lazy(opts, :path, &default_path/0)

    results =
      Typsty.Packages.get(specs, path,
        force: Keyword.get(opts, :force, false),
        report: fn message -> Mix.shell().info(message) end,
        warn: fn message -> Mix.shell().error(message) end
      )

    fetched = Enum.count(results, &match?({_package, :fetched, _imported_by}, &1))
    total = length(results)

    Mix.shell().info("""

    Downloaded #{fetched} of #{total} #{if total == 1, do: "package", else: "packages"} into #{path}. \
    Templates can import them when the :package_paths option includes that directory, in \
    config/runtime.exs:

        config :typsty, package_paths: [#{config_path(path)}]
    """)
  end

  # In a release, a directory in priv is found through the app's directory, which is only
  # known at runtime
  defp config_path("priv/" <> _ = path) do
    app = Mix.Project.config()[:app] || :my_app
    ~s|Application.app_dir(#{inspect(app)}, "#{path}")|
  end

  defp config_path(path), do: inspect(path)

  defp pinned!(package) do
    case Typsty.Packages.parse!(package) do
      {namespace, name, nil} ->
        Mix.raise(
          "@#{namespace}/#{name} in the :packages config has no version. Packages in the config must be " <>
            "pinned, like @#{namespace}/#{name}:1.0.0, since templates import exact versions. " <>
            "Run mix typsty.packages.get @#{namespace}/#{name} to fetch its latest version and see it"
        )

      _package ->
        package
    end
  end

  defp default_path do
    if Mix.Project.umbrella?() do
      Mix.raise(
        "mix typsty.packages.get saves packages in the current project's priv directory, which an umbrella " <>
          "project doesn't have. Run it in the app that renders documents (apps/my_app), or give a --path"
      )
    end

    @default_path
  end

  defp configured_packages do
    case Application.get_env(:typsty, :packages, []) do
      [_ | _] = packages ->
        Enum.map(packages, &pinned!/1)

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
