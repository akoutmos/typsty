defmodule Typsty.PackagesHTTPTest do
  # The package downloader's HTTP client, against a registry and proxies on localhost (see
  # Typsty.Test.HTTPServer). Proxies are set with environment variables, which the VM
  # shares, so these tests don't run at the same time as others
  use ExUnit.Case, async: false

  alias Typsty.Packages
  alias Typsty.Test.HTTPServer

  @moduletag :tmp_dir

  @proxy_variables ~w(HTTP_PROXY http_proxy HTTPS_PROXY https_proxy NO_PROXY no_proxy)
  @version Mix.Project.config()[:version]

  @hello %{
    "typst.toml" => ~s([package]\nname = "hello"\nversion = "1.0.0"\nentrypoint = "lib.typ"\n),
    "lib.typ" => ~s|#let hello(name) = "Hello, " + name|
  }

  @index [
    %{"name" => "hello", "version" => "0.9.0"},
    %{"name" => "hello", "version" => "1.0.0", "compiler" => "0.12.0"}
  ]

  setup %{tmp_dir: tmp_dir} do
    saved = Map.new(@proxy_variables, &{&1, System.get_env(&1)})
    Enum.each(@proxy_variables, &System.delete_env/1)

    on_exit(fn ->
      for {name, value} <- saved, do: if(value, do: System.put_env(name, value), else: System.delete_env(name))
    end)

    archive = tar_gz(tmp_dir, @hello)
    %{dir: Path.join(tmp_dir, "packages"), archive: archive, registry: HTTPServer.start(registry(archive))}
  end

  # Serves the index and hello's archive, by path, whether it's asked directly or through a
  # proxy (which gets the whole URL)
  defp registry(archive) do
    fn "GET", target, _headers ->
      case URI.parse(target).path do
        "/preview/index.json" -> {200, JSON.encode!(@index)}
        "/preview/hello-1.0.0.tar.gz" -> {200, archive}
        _other -> {404, "Not Found"}
      end
    end
  end

  defp get(specs, dir, registry, opts \\ []) do
    Packages.get(specs, dir, [registry: registry, typst_version: "0.15.1"] ++ opts)
  end

  describe "downloading" do
    test "gets the latest version from the index, saves its archive, and templates can import it",
         %{dir: dir, registry: registry} do
      assert get(["@preview/hello"], dir, registry.url) == [{{"preview", "hello", "1.0.0"}, :fetched, nil}]

      user_agent = "typsty/#{@version}"
      port = registry.port
      assert_received {:request, ^port, "GET", "/preview/index.json", %{"user-agent" => ^user_agent}}
      assert_received {:request, ^port, "GET", "/preview/hello-1.0.0.tar.gz", %{"user-agent" => ^user_agent}}

      assert File.read!(Path.join(dir, "preview/hello/1.0.0/lib.typ")) == @hello["lib.typ"]

      source = ~s|#import "@preview/hello:1.0.0": hello\n#assert.eq(hello("Ada"), "Hello, Ada")|
      assert {:ok, _svg} = Typsty.to_svg(source, %{}, package_paths: [dir])
    end

    test "works for downloads at the same time", %{dir: dir, registry: registry} do
      results =
        1..6
        |> Task.async_stream(fn i -> get(["@preview/hello:1.0.0"], Path.join(dir, "#{i}"), registry.url) end)
        |> Enum.map(fn {:ok, result} -> result end)

      assert results == List.duplicate([{{"preview", "hello", "1.0.0"}, :fetched, nil}], 6)
    end

    test "says a package that isn't on the registry doesn't exist", %{dir: dir, registry: registry} do
      assert_raise Mix.Error, "@preview/nope:1.0.0 doesn't exist on Typst Universe", fn ->
        get(["@preview/nope:1.0.0"], dir, registry.url)
      end
    end

    test "reports the status of the registry's errors", %{dir: dir} do
      server = HTTPServer.start(fn "GET", _target, _headers -> {503, "Down for maintenance"} end)

      assert_raise Mix.Error,
                   "failed to download @preview/hello:1.0.0 from #{server.url}/preview/hello-1.0.0.tar.gz: HTTP 503",
                   fn -> get(["@preview/hello:1.0.0"], dir, server.url) end

      assert_raise Mix.Error,
                   "failed to download the package index from #{server.url}/preview/index.json: HTTP 503",
                   fn ->
                     get(["@preview/hello"], dir, server.url)
                   end
    end

    test "reports a registry that can't be reached, or closes the connection", %{dir: dir} do
      port = HTTPServer.closed_port()

      assert_raise Mix.Error, ~r/: couldn't connect to 127.0.0.1:#{port}$/, fn ->
        get(["@preview/hello:1.0.0"], dir, "http://127.0.0.1:#{port}")
      end

      closing = HTTPServer.start(fn "GET", _target, _headers -> :close end)

      assert_raise Mix.Error, ~r/^failed to download @preview\/hello:1.0.0 from #{closing.url}/, fn ->
        get(["@preview/hello:1.0.0"], dir, closing.url)
      end

      refute File.exists?(Path.join(dir, "preview/hello/1.0.0"))
    end

    test "stops downloads past 64 MiB", %{dir: dir} do
      chunk = :binary.copy(<<0>>, 1024 * 1024)
      server = HTTPServer.start(fn "GET", _target, _headers -> {:repeat, 200, chunk, 65} end)

      assert_raise Mix.Error, ~r/: it's larger than 64 MiB$/, fn -> get(["@preview/hello:1.0.0"], dir, server.url) end
      refute File.exists?(Path.join(dir, "preview/hello/1.0.0"))
    end
  end

  describe "proxies" do
    test "go through HTTP_PROXY, with its user and password", %{dir: dir, archive: archive} do
      proxy = HTTPServer.start(registry(archive))
      System.put_env("HTTP_PROXY", "http://ada:p%40ss%3Aword@127.0.0.1:#{proxy.port}")

      # The registry's host doesn't exist: only the proxy can reach it
      assert [{_package, :fetched, nil}] = get(["@preview/hello:1.0.0"], dir, "http://packages.example.invalid")

      port = proxy.port
      assert_received {:request, ^port, "GET", "http://packages.example.invalid/preview/hello-1.0.0.tar.gz", headers}
      assert headers["proxy-authorization"] == "Basic " <> Base.encode64("ada:p@ss:word")
    end

    test "can be given without a scheme, in lowercase variables", %{dir: dir, archive: archive} do
      proxy = HTTPServer.start(registry(archive))
      System.put_env("http_proxy", "127.0.0.1:#{proxy.port}")

      assert [{_package, :fetched, nil}] = get(["@preview/hello:1.0.0"], dir, "http://packages.example.invalid")
      port = proxy.port
      assert_received {:request, ^port, "GET", "http://packages.example.invalid/preview/hello-1.0.0.tar.gz", headers}
      refute Map.has_key?(headers, "proxy-authorization")
    end

    test "are skipped for hosts in NO_PROXY", %{dir: dir, registry: registry} do
      System.put_env("HTTP_PROXY", "http://127.0.0.1:#{HTTPServer.closed_port()}")
      System.put_env("NO_PROXY", "example.com,127.0.0.1")

      assert [{_package, :fetched, nil}] = get(["@preview/hello:1.0.0"], dir, registry.url)
      port = registry.port
      assert_received {:request, ^port, "GET", "/preview/hello-1.0.0.tar.gz", _headers}
    end

    test "aren't used once their variable is unset", %{dir: dir, archive: archive, registry: registry} do
      proxy = HTTPServer.start(registry(archive))
      System.put_env("HTTP_PROXY", "http://127.0.0.1:#{proxy.port}")
      assert [{_package, :fetched, nil}] = get(["@preview/hello:1.0.0"], dir, registry.url)
      proxy_port = proxy.port
      assert_received {:request, ^proxy_port, "GET", _url, _headers}

      System.delete_env("HTTP_PROXY")
      assert [{_package, :fetched, nil}] = get(["@preview/hello:1.0.0"], dir, registry.url, force: true)
      registry_port = registry.port
      assert_received {:request, ^registry_port, "GET", "/preview/hello-1.0.0.tar.gz", _headers}
      refute_received {:request, ^proxy_port, _method, _target, _headers}
    end

    test "for HTTPS that want a password, or refuse, say so", %{dir: dir} do
      for {status, message} <- [
            {407, "the proxy needs a user and password (it answered 407 Proxy Authentication Required)"},
            {403, "the proxy refused to connect (403 Forbidden)"}
          ] do
        proxy = HTTPServer.start(fn "CONNECT", _target, _headers -> {status, ""} end)
        System.put_env("HTTPS_PROXY", "http://127.0.0.1:#{proxy.port}")

        assert_raise Mix.Error, ~r/: #{Regex.escape(message)}$/, fn ->
          get(["@preview/hello:1.0.0"], dir, "https://packages.example.invalid")
        end

        port = proxy.port
        assert_received {:request, ^port, "CONNECT", "packages.example.invalid:443", _headers}
      end
    end
  end

  defp tar_gz(tmp_dir, files) do
    path = Path.join(tmp_dir, "archive-#{System.unique_integer([:positive])}.tar.gz")
    entries = for {name, contents} <- files, do: {String.to_charlist(name), contents}
    :ok = :erl_tar.create(String.to_charlist(path), entries, [:compressed])
    File.read!(path)
  end
end
