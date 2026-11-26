defmodule Typsty.WorkerBuildTest do
  # Builds the pool's worker program, as compiling Typsty from source does, which replaces
  # the one the pools run: this runs on its own, after the tests that use pools
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
        WorkerBuild.build!()
      end
    end

    test "raises when cargo doesn't say where it put the worker", %{tmp_dir: dir} do
      fake_cargo!(dir, ~s(echo '{"reason":"build-finished","success":true}'; exit 0))

      %File.Stat{inode: before} = File.stat!(Path.join("priv/native", WorkerBuild.executable_name()))
      assert_raise Mix.Error, "Failed to find typsty_worker in cargo's output", fn -> WorkerBuild.build!() end

      # The worker that was there is left alone
      assert %File.Stat{inode: ^before} = File.stat!(Path.join("priv/native", WorkerBuild.executable_name()))
    end
  end

  test "a pool without its worker program says how to get it" do
    path = Path.join("priv/native", WorkerBuild.executable_name())
    moved = path <> ".moved"
    File.rename!(path, moved)

    try do
      assert_raise ArgumentError,
                   ~r/Typsty.Pool can't find its worker program at .*typsty_worker. .*mix deps.compile typsty --force/,
                   fn ->
                     Typsty.Pool.start_link(size: 1)
                   end
    after
      File.rename!(moved, path)
    end
  end

  defp fake_cargo!(dir, script) do
    cargo = Path.join(dir, "cargo")
    File.write!(cargo, "#!/bin/sh\n" <> script <> "\n")
    File.chmod!(cargo, 0o755)
  end

  test "builds the worker, replacing the one in priv/native rather than writing over it" do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    path = Path.join("priv/native", WorkerBuild.executable_name())
    %File.Stat{inode: before} = File.stat!(path)

    WorkerBuild.build!()
    assert_received {:mix_shell, :info, ["Compiling typsty_worker in release mode (native)"]}

    # A new file, in place of the old one, which running workers may still be using
    %File.Stat{inode: inode, mode: mode} = File.stat!(path)
    assert inode != before
    assert Bitwise.band(mode, 0o111) == 0o111
    assert Path.wildcard("priv/native/*.tmp") == []

    {output, 0} = System.cmd(Path.expand(path), ["--check"])
    assert output |> String.split("\n", trim: true) |> List.last() == "typsty_worker 1"

    # Pools run the new one
    pool = start_supervised!({Typsty.Pool, size: 1})
    assert {:ok, "%PDF-" <> _} = Typsty.to_pdf("Hello", %{}, pool: pool)
  end
end
