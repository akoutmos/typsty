defmodule Typsty.WorkerBuildTest do
  # Builds the pool's worker program, as compiling Typsty from source does, into directories
  # of the tests' own, rather than over the one the other tests' pools run
  use ExUnit.Case, async: false

  alias Typsty.WorkerBuild

  @moduletag :unix

  test "tracks the worker's sources, and only them" do
    native = Path.expand("native")
    sources = Enum.map(WorkerBuild.sources(), &Path.relative_to(&1, native))

    for source <- ["Cargo.toml", "Cargo.lock", "typsty_worker/src/main.rs", "typsty_core/src/world.rs"] do
      assert source in sources
    end

    assert Enum.all?(WorkerBuild.sources(), &File.regular?/1)
    refute Enum.any?(sources, &String.starts_with?(&1, "typsty_nif/"))
  end

  describe "with a cargo that fails" do
    @describetag :tmp_dir

    # A cargo that does as it's told, ahead of the real one on the PATH
    setup %{tmp_dir: dir} do
      path = System.get_env("PATH")
      System.put_env("PATH", dir <> ":" <> path)
      on_exit(fn -> System.put_env("PATH", path) end)
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    end

    test "raises with cargo's status", %{tmp_dir: dir} do
      fake_cargo!(dir, "exit 101")

      assert_raise Mix.Error, "Failed to compile typsty_worker (cargo exited with status 101)", fn ->
        WorkerBuild.build!(Path.join(dir, "native"))
      end
    end

    test "raises when cargo doesn't say where it put the worker", %{tmp_dir: dir} do
      fake_cargo!(dir, ~s(echo '{"reason":"build-finished","success":true}'; exit 0))
      destination = Path.join(dir, "native")

      assert_raise Mix.Error, "Failed to find typsty_worker in cargo's output", fn ->
        WorkerBuild.build!(destination)
      end

      assert File.ls(destination) in [{:ok, []}, {:error, :enoent}]
    end
  end

  @tag :tmp_dir
  test "a pool without its worker program says how to get it", %{tmp_dir: dir} do
    missing = Path.join(dir, WorkerBuild.executable_name())

    assert_raise ArgumentError,
                 "Typsty.Pool can't find its worker program at #{missing}. It's built with the NIF, or downloaded " <>
                   "with it: try recompiling Typsty with `mix deps.compile typsty --force`",
                 fn -> Typsty.Pool.__executable__!(missing) end
  end

  defp fake_cargo!(dir, script) do
    cargo = Path.join(dir, "cargo")
    File.write!(cargo, "#!/bin/sh\n" <> script <> "\n")
    File.chmod!(cargo, 0o755)
  end

  # A real build, which takes minutes when Cargo decides to rebuild Typst (when the variables
  # its build scripts read differ from the last build's, say)
  @tag :tmp_dir
  @tag timeout: 600_000
  test "builds the worker, replacing the one there rather than writing over it", %{tmp_dir: dir} do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    path = Path.join(dir, WorkerBuild.executable_name())
    WorkerBuild.build!(dir)
    assert_received {:mix_shell, :info, ["Compiling typsty_worker in release mode (native)"]}
    %File.Stat{inode: first} = File.stat!(path)

    # A new file, in place of the old one, which running workers may still be using
    WorkerBuild.build!(dir)
    %File.Stat{inode: second, mode: mode} = File.stat!(path)
    assert second != first
    assert Bitwise.band(mode, 0o111) == 0o111
    assert Path.wildcard(Path.join(dir, "*.tmp")) == []

    {output, 0} = System.cmd(path, ["--check"])
    assert output |> String.split("\n", trim: true) |> List.last() == "typsty_worker 1"

    # Pools can run it
    pool = start_supervised!({Typsty.Pool, size: 1, __executable__: path})
    assert {:ok, "%PDF-" <> _} = Typsty.to_pdf("Hello", %{}, pool: pool)
  end
end
