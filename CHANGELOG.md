# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

The first release.

### Added

- Document modules with `use Typsty`: `render/1` with the `~TYPST` sigil, or a colocated `.typ` template (or one
  given with the `:template` option), and generated `to_pdf/2`, `to_png/2` and `to_svg/2`, with bang variants.
- `Typsty.to_pdf/3`, `Typsty.to_png/3` and `Typsty.to_svg/3` for templates and Typst source.
- The assigns (a map) are passed to the template as a dictionary named `assigns` (`#assigns.name`), as Typst values
  rather than generated code, so they never shadow anything in Typst: strings, numbers, booleans, `nil`, lists,
  tuples, maps (as dictionaries sorted by key), dates and times, and decimals. Structs are passed as dictionaries, or
  as `Typsty.Encoder` encodes them. Using an assign that wasn't given comes with a hint that says so.
- A virtual file system: images, data files and `.typ` files are passed as binaries with the `:files` option. Files
  can also be read from a `:root` directory, which documents can't read outside of, even through symbolic links.
- Fonts from the system, from Typst's embedded fonts and from `:font_paths`, scanned once per font configuration and
  cached. `Typsty.font_families/1` lists the font families and warms the cache.
- Typst packages from local `:package_paths` directories, and `mix typsty.packages.get` to download packages from
  Typst Universe into the project (with the packages they import), as arguments or from `config :typsty, packages:`.
  Rendering never downloads packages, and a missing package's error says how to fetch it and where it looked.
- `Typsty.typst_version/0`.
- Template syntax checked at compile time, with `Typsty.SyntaxError` pointing at the line and column in the module or
  `.typ` file. `Typsty.validate/1` checks Typst source at runtime.
- `Typsty.RenderError`, with a `:reason` that tells Typst's errors (`:typst`) from timeouts (`:timeout`), renders that
  couldn't start in time (`:busy`), the pool's memory limit (`:memory_limit`) and crashes (`:crashed`), and Typst's
  diagnostics (message, hints, location and trace), mapped to the lines of the module or `.typ` file. Typst's warnings
  are logged.
- `Typsty.Formatter`, a `mix format` plugin for `~TYPST` sigils and `.typ` files, using typstyle. `Typsty.format/2`
  formats Typst source.
- PDF standards (such as PDF/A-2b and PDF/UA-1) with the `:pdf_standards` option, and the PNG resolution with `:ppi`.
- Telemetry events for every render.
- Options checked with NimbleOptions, in calls and in the application config (where unknown keys are typos), with
  errors that name the option, and option docs and typespecs generated from the same schemas.
- `Typsty.Pool`, a pool of worker processes to render in, with the `:pool` option (per render, or in the config). A
  render that runs past its timeout is stopped right away, a render can be given a memory limit (`:memory_limit`),
  and a worker that crashes takes nothing else down. Workers are replaced when they're stopped, can be recycled after
  a number of renders (`:max_renders`), and end with the pool, with the process rendering with them, and with the VM.
  Renders return what they return in the NIF, and can also read PDF files. The worker program is built from the same
  code as the NIF, and precompiled downloads include it.
- Protection for the VM:
  - Renders run on threads of their own with large stacks (as does Typst's thread pool), so deep recursion can't
    overflow a scheduler's stack, and panics become `Typsty.RenderError`s. The process that asked for a render waits
    for a message, so renders never hold up the VM's schedulers.
  - Renders time out after 60 seconds by default (`:timeout`) and are cancelled, unwinding at their next call into
    Typst. A render is cancelled too when the process waiting for it exits. At most `:max_concurrent_renders` renders
    run at once, counting cancelled renders still winding down, and `Typsty.running_renders/0` reports how many are
    running.
  - Assigns are nested at most 256 levels deep.
  - Files are checked before Typst decodes them: images claiming more than 134 megapixels, SVG and XML files nested
    more than 1,024 levels deep, compressed SVGs expanding past 128 MiB and XML entities that nest or expand past
    16 MiB are refused, as are PDF files (which renders in a `Typsty.Pool` can read). Only regular files are read from
    disk.
  - PNG export refuses pages that would need more than 2^28 pixels of textures.
  - Typst keeps every file path for the life of the VM, with room for 65,535: a render may use at most 10,000 paths,
    at most 50,000 may be given in `:files`, and renders needing a new path are stopped before the table runs out.
