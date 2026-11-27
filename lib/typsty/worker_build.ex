defmodule Typsty.WorkerBuild do
  @moduledoc false

  # Builds `typsty_worker`, the program `Typsty.Pool` runs renders in, when Typsty's native
  # code is built from source (TYPSTY_BUILD=1, or a development version). Precompiled
  # downloads include it next to the NIF.
  #
  # Like Rustler does for the NIF, it's copied into priv/native, relative to the project
  # being compiled.

  @native_dir Path.expand("../../native", __DIR__)

  @doc false
  # The worker's file name on this platform
  @spec executable_name() :: String.t()
  def executable_name do
    case :os.type() do
      {:win32, _} -> "typsty_worker.exe"
      _ -> "typsty_worker"
    end
  end

  @doc false
  # The worker's sources, which Typsty.Native tracks so that changing them rebuilds it
  @spec sources() :: [Path.t()]
  def sources do
    [
      "Cargo.toml",
      "Cargo.lock",
      ".cargo/config.toml",
      "typsty_worker/Cargo.toml",
      "typsty_worker/src/**/*.rs",
      "typsty_core/Cargo.toml",
      "typsty_core/src/**/*.rs"
    ]
    |> Enum.flat_map(&Path.wildcard(Path.join(@native_dir, &1)))
  end

  @doc false
  # Builds the worker into the directory, priv/native by default
  @spec build!(Path.t()) :: :ok
  def build!(dir \\ "priv/native") do
    Mix.shell().info("Compiling typsty_worker in release mode (#{Path.relative_to_cwd(@native_dir)})")

    args = ~w(build --release --package typsty_worker --message-format=json-render-diagnostics)

    case System.cmd("cargo", args, cd: @native_dir) do
      {output, 0} ->
        destination = Path.join(dir, executable_name())
        File.mkdir_p!(Path.dirname(destination))

        # Copied next to it and renamed into place, rather than copied over it: a running
        # worker's program can't be overwritten on Linux ("text file busy"), but it can be
        # replaced. The copy's name is unique, for builds that run at the same time
        temporary = "#{destination}.#{System.unique_integer([:positive])}-#{System.pid()}.tmp"

        try do
          File.cp!(executable!(output), temporary)
          File.chmod!(temporary, 0o755)
          File.rename!(temporary, destination)
        after
          File.rm(temporary)
        end

        Mix.Project.build_structure()

      {_output, status} ->
        Mix.raise("Failed to compile typsty_worker (cargo exited with status #{status})")
    end
  end

  # Cargo reports where it put the program in a compiler-artifact message
  defp executable!(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn line ->
      case JSON.decode(line) do
        {:ok, %{"reason" => "compiler-artifact", "target" => %{"name" => "typsty_worker"}, "executable" => path}}
        when is_binary(path) ->
          path

        _ ->
          nil
      end
    end) || Mix.raise("Failed to find typsty_worker in cargo's output")
  end
end
