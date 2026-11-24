defmodule Typsty.Packages do
  @moduledoc false

  # Downloads packages from Typst Universe into a directory laid out as
  # namespace/name/version, for `mix typsty.packages.get`. Templates import them from there
  # through the :package_paths option.

  @registry "https://packages.typst.org"
  @version Mix.Project.config()[:version]

  @spec_format ~r/^@([a-z0-9][a-z0-9_-]*)\/([A-Za-z0-9][A-Za-z0-9_-]*)(?::(\d+\.\d+\.\d+))?$/

  # Packages that a package's Typst files import, such as `#import "@preview/oxifmt:1.0.0"`
  @imported_spec ~r/"@(preview)\/([A-Za-z0-9][A-Za-z0-9_-]*):(\d+\.\d+\.\d+)/

  @typedoc ~s(A package, such as `{"preview", "cetz", "0.4.2"}`.)
  @type package :: {namespace :: String.t(), name :: String.t(), version :: String.t()}

  @typedoc "What happened to a package: downloaded, or already in the directory."
  @type result :: {package(), :fetched | :present, imported_by :: package() | nil}

  @doc false
  # Fetches the packages, and the packages they import, into the directory. Raises
  # `Mix.Error` when a package can't be fetched.
  #
  # Options:
  #
  # - :force - download packages again, even if they're already in the directory
  # - :report - a function called with a message for each package
  # - :http_get - a function that gets a URL, returning {:ok, body}, {:error, :not_found} or
  #   {:error, reason}
  # - :typst_version - the Typst version packages must work with
  @spec get([String.t()], Path.t(), keyword()) :: [result()]
  def get(specs, dir, opts \\ []) do
    context = %{
      dir: dir,
      force?: Keyword.get(opts, :force, false),
      report: Keyword.get(opts, :report, fn _message -> :ok end),
      http_get: Keyword.get(opts, :http_get, &http_get/1),
      typst_version: Keyword.get_lazy(opts, :typst_version, &Typsty.typst_version/0)
    }

    specs
    |> Enum.map(&parse!/1)
    |> resolve_versions(context)
    |> Enum.map(&{&1, nil})
    |> fetch_all(%{}, [], context)
  end

  @doc false
  @spec format(package()) :: String.t()
  def format({namespace, name, version}), do: "@#{namespace}/#{name}:#{version}"

  defp parse!(spec) do
    case Regex.run(@spec_format, spec) do
      [_, namespace, name] -> check_namespace!({namespace, name, nil}, spec)
      [_, namespace, name, version] -> check_namespace!({namespace, name, version}, spec)
      nil -> Mix.raise("invalid package #{inspect(spec)}. Packages look like @preview/cetz:0.4.2")
    end
  end

  defp check_namespace!({"preview", _name, _version} = package, _spec), do: package

  defp check_namespace!(_package, spec) do
    Mix.raise("can't fetch #{spec}: only packages in the @preview namespace are on Typst Universe")
  end

  # Packages given without a version get the latest one that works with Typsty's Typst
  defp resolve_versions(packages, context) do
    if Enum.all?(packages, fn {_namespace, _name, version} -> version end) do
      packages
    else
      index = index!(context)
      Enum.map(packages, &resolve_version(&1, index, context))
    end
  end

  defp resolve_version({_namespace, _name, version} = package, _index, _context) when is_binary(version), do: package

  defp resolve_version({namespace, name, nil}, index, context) do
    versions = for %{"name" => ^name, "version" => version} = entry <- index, do: {version, entry["compiler"]}

    compatible =
      for {version, compiler} <- versions, compiler == nil or compatible?(compiler, context.typst_version), do: version

    case Enum.max(compatible, Version, fn -> nil end) do
      nil when versions == [] ->
        Mix.raise("@#{namespace}/#{name} doesn't exist on Typst Universe")

      nil ->
        Mix.raise("no version of @#{namespace}/#{name} works with Typst #{context.typst_version}, which Typsty uses")

      version ->
        {namespace, name, version}
    end
  end

  defp index!(context) do
    url = "#{@registry}/preview/index.json"

    case context.http_get.(url) do
      {:ok, body} -> JSON.decode!(body)
      {:error, reason} -> Mix.raise("failed to download the package index from #{url}: #{describe(reason)}")
    end
  end

  defp fetch_all([], _seen, results, _context), do: Enum.reverse(results)

  defp fetch_all([{package, imported_by} | rest], seen, results, context) do
    if Map.has_key?(seen, package) do
      fetch_all(rest, seen, results, context)
    else
      dir = package_dir(context.dir, package)

      status =
        if File.dir?(dir) and not context.force? do
          :present
        else
          download!(package, imported_by, dir, context)
          :fetched
        end

      context.report.(message(package, status, imported_by))
      warn_compiler(package, dir, context)

      imports = for import <- imports(dir), import != package, do: {import, package}
      fetch_all(rest ++ imports, Map.put(seen, package, true), [{package, status, imported_by} | results], context)
    end
  end

  defp message(package, status, imported_by) do
    verb = if status == :fetched, do: "Fetched", else: "Already have"
    suffix = if imported_by, do: " (imported by #{format(imported_by)})", else: ""
    "* #{verb} #{format(package)}#{suffix}"
  end

  defp package_dir(dir, {namespace, name, version}), do: Path.join([dir, namespace, name, version])

  defp download!({namespace, name, version} = package, imported_by, dir, context) do
    url = "#{@registry}/#{namespace}/#{name}-#{version}.tar.gz"

    case context.http_get.(url) do
      {:ok, archive} ->
        extract!(archive, package, dir)

      {:error, :not_found} ->
        suffix = if imported_by, do: ", which #{format(imported_by)} imports,", else: ""
        Mix.raise("#{format(package)}#{suffix} doesn't exist on Typst Universe")

      {:error, reason} ->
        Mix.raise("failed to download #{format(package)} from #{url}: #{describe(reason)}")
    end
  end

  # The archive is extracted next to the package's directory and then moved into place, so
  # an interrupted download doesn't leave a package that looks complete
  defp extract!(archive, package, dir) do
    files =
      case :erl_tar.extract({:binary, archive}, [:compressed, :memory]) do
        {:ok, files} -> files
        {:error, reason} -> Mix.raise("the archive of #{format(package)} is invalid: #{inspect(reason)}")
      end

    tmp = "#{dir}.tmp-#{System.unique_integer([:positive])}"
    File.rm_rf!(tmp)

    try do
      for {name, contents} <- files do
        relative =
          case Path.safe_relative(to_string(name)) do
            {:ok, relative} -> relative
            :error -> Mix.raise("the archive of #{format(package)} has a file outside the package: #{name}")
          end

        path = Path.join(tmp, relative)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, contents)
      end

      File.rm_rf!(dir)
      File.mkdir_p!(Path.dirname(dir))
      File.rename!(tmp, dir)
    after
      File.rm_rf!(tmp)
    end
  end

  # The packages imported by the package's Typst files. This may include packages that are
  # only imported by its examples.
  defp imports(dir) do
    dir
    |> Path.join("**/*.typ")
    |> Path.wildcard()
    |> Enum.flat_map(fn file -> Regex.scan(@imported_spec, File.read!(file), capture: :all_but_first) end)
    |> Enum.map(fn [namespace, name, version] -> {namespace, name, version} end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp warn_compiler(package, dir, context) do
    with {:ok, manifest} <- File.read(Path.join(dir, "typst.toml")),
         [_, compiler] <- Regex.run(~r/^\s*compiler\s*=\s*"([^"]+)"/m, manifest),
         false <- compatible?(compiler, context.typst_version) do
      context.report.(
        "  warning: #{format(package)} requires Typst #{compiler} or later, but Typsty uses Typst #{context.typst_version}"
      )
    end
  end

  defp compatible?(compiler, typst_version) do
    case Version.parse(compiler) do
      {:ok, compiler} -> Version.compare(compiler, typst_version) != :gt
      :error -> true
    end
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)

  # Gets a URL with :httpc, verifying the server's certificate. Honors the HTTPS_PROXY and
  # HTTP_PROXY environment variables.
  defp http_get(url) do
    {:ok, _apps} = Application.ensure_all_started(:inets)
    {:ok, _apps} = Application.ensure_all_started(:ssl)
    configure_proxy()

    headers = [{~c"user-agent", ~c"typsty/#{@version}"}]

    http_options = [
      timeout: 120_000,
      connect_timeout: 15_000,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 3,
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]

    case :httpc.request(:get, {String.to_charlist(url), headers}, http_options, body_format: :binary) do
      {:ok, {{_version, 200, _reason}, _headers, body}} -> {:ok, body}
      {:ok, {{_version, 404, _reason}, _headers, _body}} -> {:error, :not_found}
      {:ok, {{_version, status, _reason}, _headers, _body}} -> {:error, "HTTP #{status}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp configure_proxy do
    for {option, variables} <- [https_proxy: ~w(HTTPS_PROXY https_proxy), proxy: ~w(HTTP_PROXY http_proxy)] do
      with url when is_binary(url) <- Enum.find_value(variables, &System.get_env/1),
           %URI{host: host, port: port} when is_binary(host) <- URI.parse(url) do
        :httpc.set_options([{option, {{String.to_charlist(host), port}, []}}])
      end
    end
  end
end
