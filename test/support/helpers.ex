defmodule Typsty.Test.Helpers do
  @moduledoc false
  # Helpers several test modules share

  @doc "Writes the source to a file in the directory, and compiles it."
  def compile!(dir, name, source) do
    file = Path.join(dir, name)
    File.write!(file, source)
    Code.compile_file(file)
  end

  @doc """
  The files a module declared with `@external_resource`, which Mix recompiles it for when they
  change, relative to the current directory and sorted.
  """
  def external_resources(module) do
    # Found in the code path: when tests run with coverage, the module that's loaded was
    # compiled by cover, and :code.which/1 returns :cover_compiled rather than a file
    binary = File.read!(:code.where_is_file(~c"#{module}.beam"))
    {:ok, {^module, [debug_info: {:debug_info_v1, backend, data}]}} = :beam_lib.chunks(binary, [:debug_info])
    {:ok, %{attributes: attributes}} = backend.debug_info(:elixir_v1, module, data, [])

    attributes |> Keyword.get_values(:external_resource) |> Enum.map(&Path.relative_to_cwd/1) |> Enum.sort()
  end

  @doc "Unloads a module compiled by a test, which the test can then compile again without a warning."
  def unload(module) do
    :code.delete(module)
    :code.purge(module)
  end

  @doc "A gzipped tar archive of the files (names to contents), as a package's archive is."
  def tar_gz(dir, files) do
    path = Path.join(dir, "archive-#{System.unique_integer([:positive])}.tar.gz")
    entries = for {name, contents} <- files, do: {String.to_charlist(name), contents}
    :ok = :erl_tar.create(String.to_charlist(path), entries, [:compressed])
    File.read!(path)
  end

  @doc "The width and height of a PNG, from its header."
  def png_size(<<137, "PNG", _::binary-size(12), width::32, height::32, _rest::binary>>), do: {width, height}

  @doc "Waits until the condition holds, for up to 5 seconds, returning whether it did."
  def wait_until(condition, tries \\ 500) do
    cond do
      condition.() -> true
      tries == 0 -> false
      true -> Process.sleep(10) && wait_until(condition, tries - 1)
    end
  end

  @doc """
  The line and column (both 1-based) where the text first appears in the file, which tests
  compare errors' positions with, rather than numbers that adding a line would change.
  """
  def position(file, text) do
    lines = file |> File.read!() |> String.split("\n")

    Enum.find_value(Enum.with_index(lines, 1), fn {line, number} ->
      case :binary.match(line, text) do
        {byte, _length} -> {number, String.length(binary_part(line, 0, byte)) + 1}
        :nomatch -> nil
      end
    end) || raise "#{text} isn't in #{file}"
  end
end

defmodule Typsty.Test.Telemetry do
  @moduledoc false
  # Sends the test process the metadata of the stop events of renders of a template source,
  # as {:stop, metadata}. Events of other renders (other tests', running at the same time)
  # are left out by the handler itself.

  def forward_stops(source) do
    id = "typsty-test-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach(id, [:typsty, :render, :stop], &__MODULE__.handle/4, {self(), source})
    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(id) end)
  end

  @doc false
  def handle(_event, _measurements, %{template: %{source: source}} = metadata, {test, source}) do
    send(test, {:stop, metadata})
  end

  def handle(_event, _measurements, _metadata, _config), do: :ok
end
