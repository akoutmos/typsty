defmodule Typsty.Native do
  @moduledoc false

  # The NIF is downloaded precompiled for the targets below. Set TYPSTY_BUILD=1 to build it
  # from source instead, which needs Rust. Development versions (such as 0.1.0-dev) are
  # always built from source.

  version = Mix.Project.config()[:version]

  use RustlerPrecompiled,
    otp_app: :typsty,
    crate: "typsty_nif",
    base_url: "https://github.com/akoutmos/typsty/releases/download/#{version}",
    force_build: System.get_env("TYPSTY_BUILD") in ["1", "true"],
    version: version,
    nif_versions: ["2.15"],
    targets: ~w(
      aarch64-apple-darwin
      x86_64-apple-darwin
      aarch64-unknown-linux-gnu
      x86_64-unknown-linux-gnu
      aarch64-unknown-linux-musl
      x86_64-unknown-linux-musl
      x86_64-pc-windows-gnu
      x86_64-pc-windows-msvc
    )

  # Built from source, RustlerPrecompiled doesn't load a precompiled NIF. The worker for
  # Typsty.Pool is built then too (precompiled downloads include it).
  if not Module.defines?(__MODULE__, {:load_rustler_precompiled, 0}) do
    for source <- Typsty.WorkerBuild.sources(), do: @external_resource(source)
    Typsty.WorkerBuild.build!()
  end

  def render(_template, _variables, _files, _options), do: :erlang.nif_error(:nif_not_loaded)
  def syntax_errors(_template), do: :erlang.nif_error(:nif_not_loaded)
  def format(_template, _options), do: :erlang.nif_error(:nif_not_loaded)
  def font_families(_options), do: :erlang.nif_error(:nif_not_loaded)
  def typst_version, do: :erlang.nif_error(:nif_not_loaded)
  def running_renders, do: :erlang.nif_error(:nif_not_loaded)
end
