defmodule Typsty.Packages do
  @moduledoc false

  # Downloads packages from Typst Universe into a directory laid out as
  # namespace/name/version, for `mix typsty.packages.get`. Templates import them from there
  # through the :package_paths option.

  @registry "https://packages.typst.org"
  @version Mix.Project.config()[:version]

  # The version comes from VERSION (see mix.exs), and goes in the user agent
  @external_resource Path.expand("../../VERSION", __DIR__)

  @spec_format ~r/\A@([a-z0-9][a-z0-9_-]*)\/([A-Za-z0-9][A-Za-z0-9_-]*)(?::(\d+\.\d+\.\d+))?\z/

  # Packages that a package's Typst files import, such as `#import "@preview/oxifmt:1.0.0"`
  @imported_spec ~r/"@(preview)\/([A-Za-z0-9][A-Za-z0-9_-]*):(\d+\.\d+\.\d+)/

  # Comments, which can mention imports that aren't made
  @comment ~r/\/\/[^\n]*|\/\*.*?\*\//s

  # The most a package's archive may take, downloaded and decompressed
  @max_download_size 64 * 1024 * 1024
  @max_package_size 256 * 1024 * 1024

  # A package, such as {"preview", "cetz", "0.4.2"}
  @type package :: {namespace :: String.t(), name :: String.t(), version :: String.t()}

  # What happened to a package: downloaded, or already in the directory
  @type result :: {package(), :fetched | :present, imported_by :: package() | nil}

  @doc false
  # Fetches the packages, and the packages they import, into the directory. Raises
  # `Mix.Error` when a package can't be fetched.
  #
  # Options:
  #
  # - :force - download packages again, even if they're already in the directory
  # - :report - a function called with a message for each package
  # - :warn - a function called with warnings
  # - :http_get - a function that gets a URL, returning {:ok, body}, {:error, :not_found} or
  #   {:error, reason}
  # - :typst_version - the Typst version packages must work with
  @spec get([String.t()], Path.t(), keyword()) :: [result()]
  def get(specs, dir, opts \\ []) do
    context = %{
      dir: dir,
      force?: Keyword.get(opts, :force, false),
      report: Keyword.get(opts, :report, fn _message -> :ok end),
      warn: Keyword.get(opts, :warn, fn _message -> :ok end),
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

  @doc false
  # Parses a package spec. Raises `Mix.Error` for an invalid one.
  @spec parse!(term()) :: {String.t(), String.t(), String.t() | nil}
  def parse!(spec) when is_binary(spec) do
    case Regex.run(@spec_format, spec) do
      [_, namespace, name] -> check_namespace!({namespace, name, nil}, spec)
      [_, namespace, name, version] -> check_namespace!({namespace, name, version}, spec)
      nil -> Mix.raise("invalid package #{inspect(spec)}. Packages look like @preview/cetz:0.4.2")
    end
  end

  def parse!(spec),
    do: Mix.raise("invalid package #{inspect(spec)}. Packages are strings, like \"@preview/cetz:0.4.2\"")

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
      {:ok, body} ->
        case JSON.decode(body) do
          {:ok, index} when is_list(index) -> index
          _other -> Mix.raise("the package index at #{url} isn't a list of packages")
        end

      {:error, reason} ->
        Mix.raise("failed to download the package index from #{url}: #{describe(reason)}")
    end
  end

  defp fetch_all([], _seen, results, _context), do: Enum.reverse(results)

  defp fetch_all([{package, _imported_by} | rest], seen, results, context) when is_map_key(seen, package) do
    fetch_all(rest, seen, results, context)
  end

  defp fetch_all([{package, imported_by} | rest], seen, results, context) do
    dir = package_dir(context.dir, package)
    seen = Map.put(seen, package, true)

    case fetch(package, imported_by, dir, context) do
      :missing ->
        fetch_all(rest, seen, results, context)

      status ->
        imports = for import <- imports(dir), import != package, do: {import, package}
        fetch_all(rest ++ imports, seen, [{package, status, imported_by} | results], context)
    end
  end

  defp fetch(package, imported_by, dir, context) do
    status =
      cond do
        File.dir?(dir) and not context.force? -> :present
        download(package, imported_by, dir, context) == :ok -> :fetched
        true -> :missing
      end

    if status != :missing do
      context.report.(message(package, status, imported_by))
      warn_compiler(package, dir, context)
    end

    status
  end

  defp message(package, status, imported_by) do
    verb = if status == :fetched, do: "Fetched", else: "Already have"
    suffix = if imported_by, do: " (imported by #{format(imported_by)})", else: ""
    "* #{verb} #{format(package)}#{suffix}"
  end

  defp package_dir(dir, {namespace, name, version}), do: Path.join([dir, namespace, name, version])

  defp download({namespace, name, version} = package, imported_by, dir, context) do
    url = "#{@registry}/#{namespace}/#{name}-#{version}.tar.gz"

    case context.http_get.(url) do
      {:ok, archive} ->
        extract!(archive, package, dir, context)

      # A package's files can import packages that don't exist, in examples or tests that
      # its own code doesn't use, so a missing import is only a warning
      {:error, :not_found} when imported_by != nil ->
        context.warn.(
          "warning: #{format(package)}, which #{format(imported_by)} imports, doesn't exist on Typst Universe"
        )

        :missing

      {:error, :not_found} ->
        Mix.raise("#{format(package)} doesn't exist on Typst Universe")

      {:error, reason} ->
        Mix.raise("failed to download #{format(package)} from #{url}: #{describe(reason)}")
    end
  end

  # The archive is extracted into a new directory next to the package's, and then moved into
  # place, so that an interrupted download doesn't leave a package that looks complete, and
  # so that runs at the same time don't write into each other's files
  defp extract!(archive, package, dir, context) do
    files = files!(archive, package)

    tmp = Path.join(Path.dirname(dir), ".#{Path.basename(dir)}.tmp-#{random_suffix()}")
    mkdir!(Path.dirname(dir), package)
    mkdir!(tmp, package)

    try do
      for {name, contents} <- files do
        path = Path.join(tmp, relative_path!(name, tmp, package))
        mkdir!(Path.dirname(path), package)
        write!(path, contents, package)
      end

      if context.force?, do: File.rm_rf(dir)
      move_into_place!(tmp, dir, package)
    after
      File.rm_rf(tmp)
    end
  end

  defp files!(archive, package) do
    with {:ok, tar} <- gunzip(archive, package),
         {:ok, files} <- :erl_tar.extract({:binary, tar}, [:memory]) do
      files
    else
      {:error, reason} -> Mix.raise("the archive of #{format(package)} is invalid: #{describe(reason)}")
    end
  end

  # Decompresses the archive up to @max_package_size, rather than all of it at once
  defp gunzip(archive, package) do
    z = :zlib.open()

    try do
      :zlib.inflateInit(z, 31)
      inflate(z, :zlib.safeInflate(z, archive), [], 0, package)
    rescue
      error in ErlangError -> {:error, "it isn't a gzip file (#{inspect(error.original)})"}
    after
      :zlib.close(z)
    end
  end

  defp inflate(z, {status, output}, acc, size, package) do
    size = size + IO.iodata_length(output)

    cond do
      size > @max_package_size ->
        Mix.raise("the archive of #{format(package)} expands to more than #{div(@max_package_size, 1024 * 1024)} MiB")

      status == :continue ->
        inflate(z, :zlib.safeInflate(z, []), [acc, output], size, package)

      status == :finished ->
        {:ok, IO.iodata_to_binary([acc, output])}
    end
  end

  # The entry's path within the package, checked lexically and against the files extracted
  # so far: an archive can't write outside the package
  defp relative_path!(name, tmp, package) do
    name = to_string(name)

    case Path.safe_relative(name, tmp) do
      {:ok, relative} when relative not in ["", "."] -> relative
      _ -> Mix.raise("the archive of #{format(package)} has a file outside the package: #{name}")
    end
  end

  defp move_into_place!(tmp, dir, package) do
    case File.rename(tmp, dir) do
      :ok ->
        :ok

      # Another run put the package in place first
      {:error, reason} when reason in [:eexist, :enotempty] ->
        :ok

      {:error, reason} ->
        Mix.raise("failed to save #{format(package)} in #{dir}: #{:file.format_error(reason)}")
    end
  end

  defp mkdir!(path, package) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> Mix.raise("failed to save #{format(package)}: #{path}: #{:file.format_error(reason)}")
    end
  end

  defp write!(path, contents, package) do
    case File.write(path, contents) do
      :ok -> :ok
      {:error, reason} -> Mix.raise("failed to save #{format(package)}: #{path}: #{:file.format_error(reason)}")
    end
  end

  defp random_suffix, do: 8 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  # The packages imported by the package's Typst files, leaving out comments. This may
  # include packages that are only imported by its examples.
  defp imports(dir) do
    dir
    |> Path.join("**/*.typ")
    |> Path.wildcard()
    |> Enum.flat_map(fn file ->
      text = file |> File.read!() |> String.replace(@comment, "")
      Regex.scan(@imported_spec, text, capture: :all_but_first)
    end)
    |> Enum.map(fn [namespace, name, version] -> {namespace, name, version} end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp warn_compiler(package, dir, context) do
    with {:ok, manifest} <- File.read(Path.join(dir, "typst.toml")),
         [_, compiler] <- Regex.run(~r/^\s*compiler\s*=\s*"([^"]+)"/m, manifest),
         false <- compatible?(compiler, context.typst_version) do
      context.warn.(
        "warning: #{format(package)} requires Typst #{compiler} or later, but Typsty uses Typst #{context.typst_version}"
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

  # Gets a URL with :httpc, verifying the server's certificate. Honors the HTTPS_PROXY,
  # HTTP_PROXY and NO_PROXY environment variables.
  defp http_get(url) do
    {:ok, _apps} = Application.ensure_all_started(:inets)
    {:ok, _apps} = Application.ensure_all_started(:ssl)
    proxy_auth = configure_proxy(url)

    headers = [{~c"user-agent", ~c"typsty/#{@version}"}]

    http_options =
      [
        timeout: 120_000,
        connect_timeout: 15_000,
        ssl: [
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          depth: 3,
          customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
        ]
      ] ++ proxy_auth

    case :httpc.request(:get, {String.to_charlist(url), headers}, http_options, body_format: :binary) do
      {:ok, {{_version, 200, _reason}, _headers, body}} when byte_size(body) > @max_download_size ->
        {:error, "it's larger than #{div(@max_download_size, 1024 * 1024)} MiB"}

      {:ok, {{_version, 200, _reason}, _headers, body}} ->
        {:ok, body}

      {:ok, {{_version, 404, _reason}, _headers, _body}} ->
        {:error, :not_found}

      {:ok, {{_version, status, _reason}, _headers, _body}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Returns the options for an authenticated proxy, if the proxy has a user and password
  defp configure_proxy(url) do
    no_proxy =
      ~w(NO_PROXY no_proxy)
      |> Enum.find_value("", &System.get_env/1)
      |> String.split(",", trim: true)
      |> Enum.map(&(&1 |> String.trim() |> String.to_charlist()))

    scheme = if String.starts_with?(url, "https:"), do: :https_proxy, else: :proxy

    variables =
      if scheme == :https_proxy, do: ~w(HTTPS_PROXY https_proxy HTTP_PROXY http_proxy), else: ~w(HTTP_PROXY http_proxy)

    with value when is_binary(value) <- Enum.find_value(variables, &System.get_env/1),
         value = if(String.contains?(value, "://"), do: value, else: "http://" <> value),
         %URI{host: host, port: port, userinfo: userinfo} when is_binary(host) <- URI.parse(value) do
      :httpc.set_options([{scheme, {{String.to_charlist(host), port}, no_proxy}}])

      case userinfo && String.split(userinfo, ":", parts: 2) do
        [user, password] ->
          [proxy_auth: {String.to_charlist(URI.decode(user)), String.to_charlist(URI.decode(password))}]

        _ ->
          []
      end
    else
      _ -> []
    end
  end
end
