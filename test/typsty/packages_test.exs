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
    {"evil", "1.0.0"} => %{"../../escaped.typ" => "#let x = 1"}
  }

  @index [
    %{"name" => "greet", "version" => "0.9.0", "compiler" => "0.11.0"},
    %{"name" => "greet", "version" => "1.0.0", "compiler" => "0.12.0"},
    %{"name" => "greet", "version" => "1.1.0", "compiler" => "99.0.0"},
    %{"name" => "shout", "version" => "0.2.0"},
    %{"name" => "future", "version" => "2.0.0", "compiler" => "99.0.0"}
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

    opts = [http_get: http_get, typst_version: "0.15.1", report: &send(test_pid, {:report, &1})]
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
    #assert.eq(greet(name), "HELLO WORLD")
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

  test "raises when no version works with Typsty's Typst", %{dir: dir, opts: opts} do
    assert_raise Mix.Error, "no version of @preview/future works with Typst 0.15.1, which Typsty uses", fn ->
      Packages.get(["@preview/future"], dir, opts)
    end
  end

  test "warns about a package that needs a newer Typst", %{dir: dir, opts: opts} do
    Packages.get(["@preview/future:2.0.0"], dir, opts)

    assert_received {:report,
                     "  warning: @preview/future:2.0.0 requires Typst 99.0.0 or later, but Typsty uses Typst 0.15.1"}
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

    assert_raise Mix.Error, ~r/failed to download @preview\/shout:0.2.0 from .*shout-0.2.0.tar.gz: :timeout/, fn ->
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
  end

  describe "mix typsty.packages.get" do
    test "requires packages, as arguments or in the config" do
      assert_raise Mix.Error, ~r/no packages to fetch/, fn -> Get.run([]) end
    end

    test "fetches the packages in the config" do
      Application.put_env(:typsty, :packages, ["not-a-package"])
      on_exit(fn -> Application.delete_env(:typsty, :packages) end)

      # Parsing the configured package fails before anything is downloaded
      assert_raise Mix.Error, ~r/invalid package "not-a-package"/, fn -> Get.run([]) end
    end
  end

  defp tar_gz(tmp_dir, files) do
    path = Path.join(tmp_dir, "archive-#{System.unique_integer([:positive])}.tar.gz")
    entries = for {name, contents} <- files, do: {String.to_charlist(name), contents}
    :ok = :erl_tar.create(String.to_charlist(path), entries, [:compressed])
    File.read!(path)
  end
end
