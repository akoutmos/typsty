defmodule Typsty.Native do
  @moduledoc false

  # The NIF is downloaded precompiled for the targets below. It's built from source instead
  # (which needs Rust) for development versions (such as 0.1.0-dev), when TYPSTY_BUILD=1 is
  # set, or with RustlerPrecompiled's config:
  #
  #     config :rustler_precompiled, :force_build, typsty: true

  version = Mix.Project.config()[:version]

  # The version is read from VERSION (see mix.exs), so changing it recompiles this module
  @external_resource Path.expand("../../VERSION", __DIR__)

  force_build? =
    System.get_env("TYPSTY_BUILD") in ["1", "true"] or
      Application.compile_env(:rustler_precompiled, [:force_build, :typsty], false) == true

  use RustlerPrecompiled,
    otp_app: :typsty,
    crate: "typsty_nif",
    base_url: "https://github.com/akoutmos/typsty/releases/download/#{version}",
    force_build: force_build?,
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

  # When the NIF is built from source, so is the worker for Typsty.Pool (precompiled
  # downloads include it). RustlerPrecompiled builds from source when it's forced to, for
  # versions with a "dev" pre-release, and when it's told to build every NIF from source.
  build_from_source? =
    force_build? or "dev" in Version.parse!(version).pre or
      Application.compile_env(
        :rustler_precompiled,
        :force_build_all,
        System.get_env("RUSTLER_PRECOMPILED_FORCE_BUILD_ALL") in ["1", "true"]
      ) == true

  if build_from_source? do
    for source <- Typsty.WorkerBuild.sources(), do: @external_resource(source)
    Typsty.WorkerBuild.build!()
  end

  def start_render(_reference, _template, _assigns, _files, _options), do: :erlang.nif_error(:nif_not_loaded)
  def cancel_render(_job), do: :erlang.nif_error(:nif_not_loaded)
  def syntax_errors(_template), do: :erlang.nif_error(:nif_not_loaded)
  def format(_template, _options), do: :erlang.nif_error(:nif_not_loaded)
  def font_families(_options), do: :erlang.nif_error(:nif_not_loaded)
  def typst_version, do: :erlang.nif_error(:nif_not_loaded)
  def running_renders, do: :erlang.nif_error(:nif_not_loaded)
end
