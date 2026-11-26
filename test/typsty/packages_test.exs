defmodule Typsty.PackagesTest do
  # The task tests change the application config
  use ExUnit.Case, async: false

  alias Mix.Tasks.Typsty.Packages.Get
  alias Typsty.Packages

  @moduletag :tmp_dir

  @registry "https://packages.typst.org/preview"

  # Packages served by the fake registry, as {name, version} => files
  @packages %{
    {"greet", "1.0.0"} => %{
      "typst.toml" => """
      [package]
      name = "greet"
      version = "1.0.0"
      entrypoint = "lib.typ"
      compiler = "0.12.0"
      """,
      "lib.typ" => """
      #import "@preview/shout:0.2.0": shout
      #let greet(name) = shout("Hello " + name)
      """
    },
    {"greet", "1.1.0"} => %{
      "typst.toml" => """
      [package]
      name = "greet"
      version = "1.1.0"
      entrypoint = "lib.typ"
      compiler = "99.0.0"
      """,
      "lib.typ" => "#let greet(name) = name"
    },
    {"shout", "0.2.0"} => %{
      "typst.toml" => """
      [package]
      name = "shout"
      version = "0.2.0"
      entrypoint = "src/shout.typ"
      """,
      "src/shout.typ" => "#let shout(text) = upper(text)",
      # Imports itself in an example, which shouldn't be fetched again
      "examples/demo.typ" => ~s|#import "@preview/shout:0.2.0": shout|
    },
    # Imports after a "/*" in a string, and Typst's own syntax for everything else
    {"stringy", "1.0.0"} => %{
      "lib.typ" => """
      #let glob = "src/*"
      #import "@preview/shout:0.2.0": shout
      /* a comment */
      ```typ
      #import "@preview/in-raw:1.0.0"
      ```
      """
    },
    {"newer", "0.9.0"} => %{"lib.typ" => "#let x = 1"},
    {"newer", "1.0.0"} => %{
      "typst.toml" => """
      [package]
      name = "newer"
      version = "1.0.0"
      entrypoint = "lib.typ"
      compiler = "0.16"
      """,
      "lib.typ" => "#let x = 1"
    },
    {"future", "2.0.0"} => %{
      "typst.toml" => """
      [package]
      name = "future"
      version = "2.0.0"
      entrypoint = "lib.typ"
      compiler = "99.0.0"
      """,
      "lib.typ" => "#let x = 1"
    },
    {"evil", "1.0.0"} => %{"../../escaped.typ" => "#let x = 1"},
    # A file where the archive later needs a directory
    {"clash", "1.0.0"} => %{"lib" => "a file", "lib/x.typ" => "#let x = 1"},
    # Two packages that import the same one
    {"left", "1.0.0"} => %{"lib.typ" => ~s|#import "@preview/shout:0.2.0": shout|},
    {"right", "1.0.0"} => %{"lib.typ" => ~s|#import "@preview/shout:0.2.0": shout|},
    # Imports from namespaces other than @preview, which aren't on Typst Universe
    {"mixed", "1.0.0"} => %{
      "lib.typ" => ~s|#import "@local/thing:1.0.0": x\n#import "@preview/shout:0.2.0": shout|
    },
    # Compiler bounds with only a major version, and one that isn't a version
    {"bounds", "1.0.0"} => %{"typst.toml" => ~s|[package]\ncompiler = "1"\n|, "lib.typ" => "#let x = 1"},
    {"bounds", "0.5.0"} => %{"typst.toml" => ~s|[package]\ncompiler = "next"\n|, "lib.typ" => "#let x = 1"},
    {"dot", "1.0.0"} => %{"." => "x"},
    {"empty", "1.0.0"} => %{},
    {"commented", "1.0.0"} => %{
      "lib.typ" => """
      // #import "@preview/nope:9.9.9"
      /* #import "@preview/nope:8.8.8" */
      #let x = 1
      """,
      # An example importing a package that doesn't exist
      "examples/demo.typ" => ~s|#import "@preview/gone:1.0.0"|
    }
  }

  @index [
    %{"name" => "greet", "version" => "0.9.0", "compiler" => "0.11.0"},
    %{"name" => "greet", "version" => "1.0.0", "compiler" => "0.12.0"},
    %{"name" => "greet", "version" => "1.1.0", "compiler" => "99.0.0"},
    %{"name" => "shout", "version" => "0.2.0"},
    %{"name" => "future", "version" => "2.0.0", "compiler" => "99.0.0"},
    %{"name" => "newer", "version" => "0.9.0"},
    %{"name" => "newer", "version" => "1.0.0", "compiler" => "0.16"},
    %{"name" => "bounds", "version" => "1.0.0", "compiler" => "1"},
    %{"name" => "bounds", "version" => "0.5.0", "compiler" => "next"},
    # Versions become paths
    %{"name" => "escape", "version" => "../../../../escaped"},
    %{"name" => "escape", "version" => ["1.0.0"]}
  ]

  setup %{tmp_dir: tmp_dir} do
    archives =
      Map.new(@packages, fn {{name, version}, files} ->
        {"#{@registry}/#{name}-#{version}.tar.gz", tar_gz(tmp_dir, files)}
      end)

    test_pid = self()

    http_get = fn url ->
      send(test_pid, {:get, url})

      cond do
        url == "#{@registry}/index.json" -> {:ok, JSON.encode!(@index)}
        Map.has_key?(archives, url) -> {:ok, archives[url]}
        true -> {:error, :not_found}
      end
    end

    opts = [
      http_get: http_get,
      typst_version: "0.15.1",
      report: &send(test_pid, {:report, &1}),
      warn: &send(test_pid, {:warn, &1})
    ]

    %{dir: Path.join(tmp_dir, "packages"), opts: opts}
  end

  test "fetches a package and the packages it imports", %{dir: dir, opts: opts} do
    assert [
             {{"preview", "greet", "1.0.0"}, :fetched, nil},
             {{"preview", "shout", "0.2.0"}, :fetched, {"preview", "greet", "1.0.0"}}
           ] = Packages.get(["@preview/greet:1.0.0"], dir, opts)

    assert File.read!(Path.join(dir, "preview/greet/1.0.0/lib.typ")) =~ "#let greet"
    assert File.read!(Path.join(dir, "preview/shout/0.2.0/src/shout.typ")) =~ "#let shout"
    assert Path.wildcard(Path.join(dir, "**/*.tmp-*")) == []

    assert_received {:report, "* Fetched @preview/greet:1.0.0"}
    assert_received {:report, "* Fetched @preview/shout:0.2.0 (imported by @preview/greet:1.0.0)"}
    refute_received {:get, "#{@registry}/index.json"}
  end

  test "the fetched packages can be imported by templates", %{dir: dir, opts: opts} do
    Packages.get(["@preview/greet:1.0.0"], dir, opts)

    source = ~S"""
    #import "@preview/greet:1.0.0": greet
    #assert.eq(greet(assigns.name), "HELLO WORLD")
    """

    assert {:ok, _pdf} = Typsty.to_pdf(source, %{name: "World"}, package_paths: [dir])
  end

  test "doesn't download packages that are already there, unless forced", %{dir: dir, opts: opts} do
    Packages.get(["@preview/shout:0.2.0"], dir, opts)
    assert_received {:get, _url}

    assert [{_package, :present, nil}] = Packages.get(["@preview/shout:0.2.0"], dir, opts)
    refute_received {:get, _url}
    assert_received {:report, "* Already have @preview/shout:0.2.0"}

    assert [{_package, :fetched, nil}] = Packages.get(["@preview/shout:0.2.0"], dir, [force: true] ++ opts)
    assert_received {:get, _url}
  end

  test "gets the latest version that works with Typsty's Typst", %{dir: dir, opts: opts} do
    assert [{{"preview", "greet", "1.0.0"}, :fetched, nil} | _] = Packages.get(["@preview/greet"], dir, opts)
    assert_received {:get, "#{@registry}/index.json"}

    # With a newer Typst, the newest version works
    assert [{{"preview", "greet", "1.1.0"}, :fetched, nil}] =
             Packages.get(["@preview/greet"], dir, Keyword.put(opts, :typst_version, "99.0.0"))
  end

  test "reads compiler bounds without a minor or patch version", %{dir: dir, opts: opts} do
    assert [{{"preview", "newer", "0.9.0"}, :fetched, nil}] = Packages.get(["@preview/newer"], dir, opts)

    Packages.get(["@preview/newer:1.0.0"], dir, opts)
    assert_received {:warn, "warning: @preview/newer:1.0.0 requires Typst 0.16 or later, but Typsty uses Typst 0.15.1"}
  end

  test "finds imports with Typst's parser, so strings and raw text don't hide or fake them", %{dir: dir, opts: opts} do
    assert [_stringy, {{"preview", "shout", "0.2.0"}, :fetched, _}] =
             Packages.get(["@preview/stringy:1.0.0"], dir, opts)

    refute_received {:get, "https://packages.typst.org/preview/in-raw-" <> _}
  end

  test "removes temporary directories that interrupted runs left behind", %{dir: dir, opts: opts} do
    stale = Path.join(dir, "preview/greet/.1.0.0.tmp-leftover")
    File.mkdir_p!(stale)
    File.touch!(stale, System.os_time(:second) - 3600)

    Packages.get(["@preview/greet:1.1.0"], dir, Keyword.put(opts, :typst_version, "99.0.0"))
    refute File.exists?(stale)
  end

  test "skips the proxy for hosts in NO_PROXY, the way curl does" do
    on_exit(fn -> System.delete_env("NO_PROXY") end)

    for {no_proxy, expected} <- [
          {"packages.typst.org", true},
          {"typst.org", true},
          {".typst.org", true},
          {"*", true},
          {"example.com, TYPST.ORG:443", true},
          {"ypst.org", false},
          {"", false}
        ] do
      System.put_env("NO_PROXY", no_proxy)
      assert Packages.no_proxy?("packages.typst.org") == expected, "NO_PROXY=#{inspect(no_proxy)}"
    end
  end

  test "raises when no version works with Typsty's Typst", %{dir: dir, opts: opts} do
    assert_raise Mix.Error, "no version of @preview/future works with Typst 0.15.1, which Typsty uses", fn ->
      Packages.get(["@preview/future"], dir, opts)
    end
  end

  test "warns about a package that needs a newer Typst", %{dir: dir, opts: opts} do
    Packages.get(["@preview/future:2.0.0"], dir, opts)

    assert_received {:warn,
                     "warning: @preview/future:2.0.0 requires Typst 99.0.0 or later, but Typsty uses Typst 0.15.1"}
  end

  test "raises for packages that don't exist", %{dir: dir, opts: opts} do
    assert_raise Mix.Error, "@preview/nope:1.0.0 doesn't exist on Typst Universe", fn ->
      Packages.get(["@preview/nope:1.0.0"], dir, opts)
    end

    assert_raise Mix.Error, "@preview/nope doesn't exist on Typst Universe", fn ->
      Packages.get(["@preview/nope"], dir, opts)
    end
  end

  test "raises for download errors", %{dir: dir, opts: opts} do
    opts = Keyword.put(opts, :http_get, fn _url -> {:error, :timeout} end)

    assert_raise Mix.Error, ~r/failed to download @preview\/shout:0.2.0 from .*shout-0.2.0.tar.gz: it timed out/, fn ->
      Packages.get(["@preview/shout:0.2.0"], dir, opts)
    end
  end

  test "rejects archives with files outside the package", %{dir: dir, opts: opts} do
    assert_raise Mix.Error, ~r/has a file outside the package/, fn ->
      Packages.get(["@preview/evil:1.0.0"], dir, opts)
    end

    refute File.exists?(Path.join(dir, "preview/evil/1.0.0"))
    assert Path.wildcard(Path.join(dir, "**/*escaped*")) == []
  end

  test "ignores imports in comments, and only warns about missing packages that packages import",
       %{dir: dir, opts: opts} do
    assert [{{"preview", "commented", "1.0.0"}, :fetched, nil}] = Packages.get(["@preview/commented:1.0.0"], dir, opts)

    assert_received {:warn,
                     "warning: @preview/gone:1.0.0, which @preview/commented:1.0.0 imports, doesn't exist on Typst Universe"}

    refute_received {:get, "https://packages.typst.org/preview/nope-" <> _}
  end

  test "raises for archives with files outside the package, and saves empty ones", %{dir: dir, opts: opts} do
    assert_raise Mix.Error, ~r/has a file outside the package/, fn ->
      Packages.get(["@preview/dot:1.0.0"], dir, opts)
    end

    # An empty package is saved as an empty directory
    assert [{_, :fetched, nil}] = Packages.get(["@preview/empty:1.0.0"], dir, opts)
    assert File.dir?(Path.join(dir, "preview/empty/1.0.0"))

    opts = Keyword.put(opts, :http_get, fn _url -> {:ok, "not gzip"} end)

    assert_raise Mix.Error, ~r/the archive of @preview\/shout:0.2.0 is invalid/, fn ->
      Packages.get(["@preview/shout:0.2.0"], dir, opts)
    end
  end

  test "extracts packages the same way whatever the current directory holds", %{dir: dir, opts: opts, tmp_dir: tmp_dir} do
    # Archive entries were once checked against the current directory, following its links
    project = Path.join(tmp_dir, "project")
    File.mkdir_p!(Path.join(project, "elsewhere"))
    File.ln_s!(Path.join(project, "elsewhere"), Path.join(project, "src"))

    File.cd!(project, fn -> Packages.get(["@preview/shout:0.2.0"], dir, opts) end)
    assert File.regular?(Path.join(dir, "preview/shout/0.2.0/src/shout.typ"))
  end

  test "runs at the same time don't break each other's packages", %{dir: dir, opts: opts} do
    1..8
    |> Task.async_stream(fn _ -> Packages.get(["@preview/greet:1.0.0"], dir, opts) end, max_concurrency: 8)
    |> Enum.each(fn result -> assert {:ok, [_ | _]} = result end)

    assert File.read!(Path.join(dir, "preview/greet/1.0.0/lib.typ")) =~ "#let greet"
    assert Path.wildcard(Path.join(dir, "**/.*.tmp-*"), match_dot: true) == []
  end

  test "ignores versions in the index that aren't versions", %{dir: dir, opts: opts} do
    assert_raise Mix.Error, ~r/@preview\/escape doesn't exist on Typst Universe/, fn ->
      Packages.get(["@preview/escape"], dir, opts)
    end

    assert Path.wildcard(Path.join([dir, "..", "**", "escaped"])) == []
  end

  test "raises for an index that isn't a list of packages", %{dir: dir, opts: opts} do
    opts = Keyword.put(opts, :http_get, fn _url -> {:ok, "<html>"} end)

    assert_raise Mix.Error, ~r/the package index at .* isn't a list of packages/, fn ->
      Packages.get(["@preview/greet"], dir, opts)
    end
  end

  test "raises for an archive with a file where it needs a directory", %{dir: dir, opts: opts} do
    assert_raise Mix.Error, ~r"^the archive of @preview/clash:1.0.0 is invalid: lib/x.typ: ", fn ->
      Packages.get(["@preview/clash:1.0.0"], dir, opts)
    end

    refute File.exists?(Path.join(dir, "preview/clash/1.0.0"))
    assert Path.wildcard(Path.join(dir, "preview/clash/.*"), match_dot: true) == []
  end

  test "raises for gzip files that aren't tar archives", %{dir: dir, opts: opts} do
    opts = Keyword.put(opts, :http_get, fn _url -> {:ok, :zlib.gzip(String.duplicate("not a tar archive ", 100))} end)

    assert_raise Mix.Error, ~r"^the archive of @preview/shout:0.2.0 is invalid: ", fn ->
      Packages.get(["@preview/shout:0.2.0"], dir, opts)
    end
  end

  test "refuses archives that expand past 256 MiB, before they're all decompressed", %{dir: dir, opts: opts} do
    # 257 MiB of zeros, compressed a MiB at a time, which takes about 256 KiB
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, :best_compression, :deflated, 31, 8, :default)
    zeros = :binary.copy(<<0>>, 1024 * 1024)
    bomb = IO.iodata_to_binary([for(_ <- 1..257, do: :zlib.deflate(z, zeros)), :zlib.deflate(z, [], :finish)])
    :zlib.close(z)
    assert byte_size(bomb) < 1024 * 1024

    opts = Keyword.put(opts, :http_get, fn _url -> {:ok, bomb} end)

    assert_raise Mix.Error, "the archive of @preview/shout:0.2.0 expands to more than 256 MiB", fn ->
      Packages.get(["@preview/shout:0.2.0"], dir, opts)
    end
  end

  test "extracts large files whole", %{dir: dir, opts: opts, tmp_dir: tmp_dir} do
    data = :crypto.strong_rand_bytes(3 * 1024 * 1024)
    archive = tar_gz(tmp_dir, %{"lib.typ" => "#let x = 1", "data/blob.bin" => data})
    opts = Keyword.put(opts, :http_get, fn _url -> {:ok, archive} end)

    assert [{_package, :fetched, nil}] = Packages.get(["@preview/shout:0.2.0"], dir, opts)
    assert File.read!(Path.join(dir, "preview/shout/0.2.0/data/blob.bin")) == data
  end

  test "raises when the directory can't be created", %{opts: opts, tmp_dir: tmp_dir} do
    file = Path.join(tmp_dir, "a-file")
    File.write!(file, "")

    assert_raise Mix.Error, ~r"^failed to save @preview/shout:0.2.0: #{file}/preview/shout: ", fn ->
      Packages.get(["@preview/shout:0.2.0"], file, opts)
    end
  end

  test "raises when something that isn't a package is in the package's place", %{dir: dir, opts: opts} do
    path = Path.join(dir, "preview/shout/0.2.0")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "a file, not a directory")

    assert_raise Mix.Error, ~r"^failed to save @preview/shout:0.2.0 in #{path}: ", fn ->
      Packages.get(["@preview/shout:0.2.0"], dir, opts)
    end

    assert File.read!(path) == "a file, not a directory"
    assert Path.wildcard(Path.join(dir, "preview/shout/.*"), match_dot: true) == []
  end

  test "fetches a package that several packages import once", %{dir: dir, opts: opts} do
    assert [
             {{"preview", "left", "1.0.0"}, :fetched, nil},
             {{"preview", "right", "1.0.0"}, :fetched, nil},
             {{"preview", "shout", "0.2.0"}, :fetched, {"preview", "left", "1.0.0"}}
           ] = Packages.get(["@preview/left:1.0.0", "@preview/right:1.0.0"], dir, opts)

    assert_received {:get, "#{@registry}/shout-0.2.0.tar.gz"}
    refute_received {:get, "#{@registry}/shout-0.2.0.tar.gz"}
  end

  test "only fetches the imports in @preview", %{dir: dir, opts: opts} do
    assert [_mixed, {{"preview", "shout", "0.2.0"}, :fetched, _}] = Packages.get(["@preview/mixed:1.0.0"], dir, opts)
    refute_received {:get, "https://packages.typst.org/local/" <> _}
  end

  test "reads compiler bounds with only a major version, and takes ones that aren't versions as met",
       %{dir: dir, opts: opts} do
    # 1.0.0 needs Typst 1, and 0.5.0's bound can't be read
    assert [{{"preview", "bounds", "0.5.0"}, :fetched, nil}] = Packages.get(["@preview/bounds"], dir, opts)
    refute_received {:warn, _message}

    Packages.get(["@preview/bounds:1.0.0"], dir, opts)
    assert_received {:warn, "warning: @preview/bounds:1.0.0 requires Typst 1 or later, but Typsty uses Typst 0.15.1"}
  end

  test "gets the latest version of the packages given without one, alongside pinned ones", %{dir: dir, opts: opts} do
    assert [
             {{"preview", "shout", "0.2.0"}, :fetched, nil},
             {{"preview", "greet", "1.0.0"}, :fetched, nil}
           ] = Packages.get(["@preview/shout:0.2.0", "@preview/greet"], dir, opts)

    assert_received {:get, "#{@registry}/index.json"}
  end

  test "takes no reporting functions", %{dir: dir, opts: opts} do
    opts = Keyword.drop(opts, [:report, :warn])
    assert [{_package, :fetched, nil}] = Packages.get(["@preview/future:2.0.0"], dir, opts)
    assert [{_package, :present, nil}] = Packages.get(["@preview/future:2.0.0"], dir, opts)
  end

  test "raises for invalid packages", %{dir: dir, opts: opts} do
    assert_raise Mix.Error, ~r/invalid package "cetz". Packages look like @preview\/cetz:0.4.2/, fn ->
      Packages.get(["cetz"], dir, opts)
    end

    assert_raise Mix.Error, ~r/only packages in the @preview namespace are on Typst Universe/, fn ->
      Packages.get(["@local/mine:1.0.0"], dir, opts)
    end
  end

  test "rendering suggests fetching a missing package" do
    assert {:error, %Typsty.RenderError{diagnostics: [diagnostic]}} =
             Typsty.to_pdf(~S|#import "@preview/greet:1.0.0": greet|)

    assert diagnostic.message == "package not found (searched for @preview/greet:1.0.0)"
    assert List.last(diagnostic.hints) =~ "download it with `mix typsty.packages.get @preview/greet:1.0.0`"
    assert List.last(diagnostic.hints) =~ "The :package_paths option is empty"

    assert {:error, %Typsty.RenderError{diagnostics: [diagnostic]}} =
             Typsty.to_pdf(~S|#import "@preview/greet:1.0.0": greet|, %{}, package_paths: ["/no/such/dir"])

    # The path as it was searched, which on Windows has the current drive
    assert List.last(diagnostic.hints) =~ "Searched #{Path.expand("/no/such/dir")} (which doesn't exist)"
  end

  test "rendering only hints at packages for Typst's own message" do
    # A message that quotes a template's data
    source = ~S|#panic("package not found (searched for @preview/greet:1.0.0)")|
    assert {:error, %Typsty.RenderError{diagnostics: [diagnostic]}} = Typsty.to_pdf(source)
    assert diagnostic.hints == []
  end

  test "rendering suggests the :package_paths option for packages in other namespaces" do
    assert {:error, %Typsty.RenderError{diagnostics: [diagnostic]}} =
             Typsty.to_pdf(~S|#import "@local/mine:1.0.0": mine|)

    assert List.last(diagnostic.hints) =~
             "add the directory that holds local/mine/1.0.0 to the :package_paths option"
  end

  test "rendering says when :package_paths names the namespace's directory", %{dir: dir, opts: opts} do
    Packages.get(["@preview/shout:0.2.0"], dir, opts)
    source = ~S|#import "@preview/shout:0.2.0": shout|

    assert {:error, %Typsty.RenderError{diagnostics: [diagnostic]}} =
             Typsty.to_pdf(source, %{}, package_paths: [Path.join(dir, "preview")])

    assert List.last(diagnostic.hints) =~
             "has the package, but :package_paths must name the directory that holds preview/: #{dir}"
  end

  describe "mix typsty.packages.get" do
    test "requires packages, as arguments or in the config" do
      assert_raise Mix.Error, ~r/no packages to fetch/, fn -> Get.run([]) end
    end

    test "checks the packages in the config before downloading anything" do
      on_exit(fn -> Application.delete_env(:typsty, :packages) end)

      Application.put_env(:typsty, :packages, ["not-a-package"])
      assert_raise Mix.Error, ~r/invalid package "not-a-package"/, fn -> Get.run([]) end

      Application.put_env(:typsty, :packages, [:cetz])
      assert_raise Mix.Error, ~r/invalid package :cetz. Packages are strings/, fn -> Get.run([]) end

      Application.put_env(:typsty, :packages, ["@preview/cetz"])
      assert_raise Mix.Error, ~r/@preview\/cetz in the :packages config has no version/, fn -> Get.run([]) end
    end

    test "reports what it did", %{dir: dir, opts: opts} do
      # Already downloaded, so the task doesn't need the network
      Packages.get(["@preview/shout:0.2.0"], dir, opts)
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

      Get.run(["--path", dir, "@preview/shout:0.2.0"])

      assert_received {:mix_shell, :info, ["* Already have @preview/shout:0.2.0"]}
      assert_received {:mix_shell, :info, [summary]}
      assert summary =~ "Downloaded 0 of 1 package into #{dir}."
      assert summary =~ "config :typsty, package_paths:"
    end
  end

  describe "mix typsty.packages.get, with packages already downloaded" do
    setup do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    end

    test "warns about packages that need a newer Typst", %{dir: dir, opts: opts} do
      Packages.get(["@preview/future:2.0.0"], dir, opts)
      Get.run(["--path", dir, "@preview/future:2.0.0"])

      assert_received {:mix_shell, :error,
                       ["warning: @preview/future:2.0.0 requires Typst 99.0.0 or later, but Typsty uses Typst " <> _]}
    end

    test "fetches the packages in the config", %{dir: dir, opts: opts} do
      on_exit(fn -> Application.delete_env(:typsty, :packages) end)
      Packages.get(["@preview/shout:0.2.0"], dir, opts)
      Application.put_env(:typsty, :packages, ["@preview/shout:0.2.0"])

      Get.run(["--path", dir])
      assert_received {:mix_shell, :info, ["* Already have @preview/shout:0.2.0"]}
    end

    test "suggests finding a directory in priv with Application.app_dir/2", %{opts: opts, tmp_dir: tmp_dir} do
      File.cd!(tmp_dir, fn ->
        Packages.get(["@preview/shout:0.2.0"], "priv/typst/packages", opts)
        Get.run(["--path", "priv/typst/packages", "@preview/shout:0.2.0"])
      end)

      assert_received {:mix_shell, :info, ["* Already have @preview/shout:0.2.0"]}
      assert_received {:mix_shell, :info, [summary]}
      assert summary =~ ~s|config :typsty, package_paths: [Application.app_dir(:typsty, "priv/typst/packages")]|
    end
  end

  test "mix typsty.packages.get needs the config's packages to be a list" do
    on_exit(fn -> Application.delete_env(:typsty, :packages) end)
    Application.put_env(:typsty, :packages, "@preview/shout:0.2.0")

    assert_raise Mix.Error, ~s|the :packages config must be a list of packages, got: "@preview/shout:0.2.0"|, fn ->
      Get.run([])
    end
  end

  test "mix typsty.packages.get needs a --path in an umbrella project", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "mix.exs"), """
    defmodule Typsty.PackagesTest.Umbrella.MixProject do
      use Mix.Project
      def project, do: [apps_path: "apps", deps: []]
    end
    """)

    assert_raise Mix.Error, ~r/which an umbrella project doesn't have. .* or give a --path/, fn ->
      Mix.Project.in_project(:umbrella, tmp_dir, fn _module -> Get.run(["@preview/shout:0.2.0"]) end)
    end
  end

  defp tar_gz(tmp_dir, files) do
    path = Path.join(tmp_dir, "archive-#{System.unique_integer([:positive])}.tar.gz")
    entries = for {name, contents} <- files, do: {String.to_charlist(name), contents}
    :ok = :erl_tar.create(String.to_charlist(path), entries, [:compressed])
    File.read!(path)
  end
end
