# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

The first release, with Typst 0.15.1. The NIF and the pool's worker are
precompiled for macOS (Apple Silicon and Intel), Linux (x86-64 and ARM64, glibc
and musl) and Windows (x86-64).

### Added

- Document modules with `use Typsty`: `render/1` with the `~TYPST` sigil, or a
  colocated `.typ` template (or one given with the `:template` option), and
  generated `to_pdf/2`, `to_png/2` and `to_svg/2`, with bang variants.
- Components, with `use Typsty.Component`: reusable Typst functions (tables,
  letterheads, headers and footers), in a `.typ` file or a `~TYPST` sigil.
  - Documents list them (`use Typsty, components: [...]`, or the `:components`
    option) and import them from `components/<name>.typ`, with the components
    they list. The `:name` option names a component.
  - They're checked when they compile: their top level can only have
    definitions and imports, and they can't read `sys.inputs` (or use `eval`),
    so they only get data as arguments. Their errors point at the lines of
    their files, and `Typsty.SyntaxError` has a `:kind` (`:syntax` or
    `:component`).
  - A component's own files (images, data and `.typ` files) go in a folder next
    to it (or the one given with `files:`), are kept in its module, and are
    served at `components/<name>/`. The paths it reads them from, written as
    strings, are checked when it compiles.
  - Documents depend on components at runtime only, so changing one doesn't
    recompile them.
  - `components/` is reserved: `:files` can't have files there, and it isn't
    read from `:root`, so a file in `:files` can't take a component's place.
- `Typsty.to_pdf/3`, `Typsty.to_png/3` and `Typsty.to_svg/3` for templates and
  Typst source.
- The assigns (a map) are passed to the template as a dictionary named `assigns`
  (`#assigns.name`), as Typst values rather than generated code, so they never
  shadow anything in Typst: strings, numbers, booleans, `nil`, lists, tuples,
  maps (as dictionaries sorted by key), dates and times, decimals, `MapSet`s,
  `Range`s and `Date.Range`s. Other structs implement `Typsty.Encoder`, by
  deriving it (`@derive {Typsty.Encoder, only: [...]}`) or implementing it. Using
  an assign that wasn't given comes with a hint that says so. Imported files
  other than components can read the assigns from `sys.inputs.assigns`.
- A virtual file system: images, data files and `.typ` files are passed as
  binaries with the `:files` option. Files can also be read from a `:root`
  directory, which documents can't read outside of, even through symbolic links
  (unless one is swapped in while a document reads it).
- Fonts from the system, from Typst's embedded fonts and from `:font_paths`,
  scanned once per font configuration and cached. `Typsty.font_families/1` lists
  the font families and warms the cache.
- Typst packages from local `:package_paths` directories, and
  `mix typsty.packages.get` to download packages from Typst Universe into the
  project (with the packages they import), as arguments or from
  `config :typsty, packages:`, through the HTTP proxy in `HTTPS_PROXY` or
  `HTTP_PROXY` (but for the hosts in `NO_PROXY`). Rendering never downloads
  packages, and a missing package's error says how to fetch it and where it
  looked.
- `Typsty.typst_version/0`.
- Template syntax checked at compile time, with `Typsty.SyntaxError` pointing at
  the line and column in the module or `.typ` file. `Typsty.validate/1` checks
  Typst source at runtime.
- `Typsty.RenderError`, with a `:reason` that tells Typst's errors (`:typst`)
  from timeouts (`:timeout`), renders that couldn't start in time (`:busy`), the
  pool's memory limit (`:memory_limit`) and crashes (`:crashed`), and Typst's
  diagnostics (message, hints, location and trace), mapped to the lines of the
  module or `.typ` file, with the warnings that came before the errors. Typst's
  warnings are logged.
- `Typsty.Formatter`, a `mix format` plugin for `~TYPST` sigils and `.typ`
  files, using typstyle. `Typsty.format/2` formats Typst source.
- PDF standards (such as PDF/A-2b and PDF/UA-1) with the `:pdf_standards`
  option, and the PNG resolution with `:ppi`.
- Telemetry events for every render.
- Options checked with NimbleOptions, in calls and in the application config
  (where unknown keys are typos), with errors that name the option, and option
  docs and typespecs generated from the same schemas.
- `Typsty.Pool`, a pool of worker processes to render in, with the `:pool`
  option (per render, or in the config), favored for input from untrusted users
  that isn't well validated. A render that runs past its timeout is stopped
  right away, renders can be held to a memory limit set for the pool
  (`:memory_limit`), and a worker that crashes takes nothing else down. Workers get only the environment
  variables that finding fonts needs. A pool starts once its workers have
  started and loaded their fonts, so that the first renders don't wait for them.
  Workers are replaced when they're stopped, can be recycled after a number of
  renders (`:max_renders`), and end with the pool, with the process rendering
  with them, and with the VM. Renders return what they return in the NIF, and
  can also read PDF files and SVGs that contain SVGs. The worker program is built from the same code as the
  NIF, and precompiled downloads include it.
- Protection for the VM:
  - Renders run on threads of their own with large stacks (as does Typst's
    thread pool), so deep recursion can't overflow a scheduler's stack, and
    panics become `Typsty.RenderError`s. The process that asked for a render
    waits for a message, so renders never hold up the VM's schedulers.
  - Renders time out after 60 seconds by default (`:timeout`) and are cancelled,
    unwinding at their next call into Typst. A render is cancelled too when the
    process waiting for it exits. At most `:max_concurrent_renders` renders run
    at once, counting cancelled renders still winding down, and
    `Typsty.running_renders/0` reports how many are running.
  - Assigns are nested at most 128 levels deep.
  - Links can only go to http, https, mailto and tel URLs (or relative ones):
    others, such as `javascript:` URLs from a template's data, are left out of
    PDFs and SVGs with a warning. SVGs escape the URLs that Typst doesn't.
  - PNG export refuses content placed far off the page, which takes minutes to
    draw.
  - Renders with large assigns or files (over 32 MiB) drop Typst's caches when
    they finish, rather than keep them for later renders.
  - Files are checked before Typst decodes them: images claiming more than 134
    megapixels (including images inside SVGs), SVG and XML files nested more
    than 1,024 levels deep, compressed SVGs expanding past 128 MiB, XML entities
    that nest or expand past 16 MiB, SVGs with content far outside their canvas,
    SVG turbulence filters of more than 24 octaves, PNG color profiles that
    expand past 16 MiB, images without pixels, CBOR that declares more items
    than it holds, deeply nested bibliographies and BibTeX references that cycle
    or expand exponentially are refused, as are PDF files and SVGs inside SVGs
    (which renders in a `Typsty.Pool` can read). Only regular files of at most
    512 MiB are read from disk.
  - PNG export refuses pages that would need more than 2^28 pixels of textures.
  - Typst keeps every file path for the life of the VM, with room for 65,535: a
    render may use at most 10,000 paths, at most 50,000 different paths may be
    given in `:files` over the life of the VM (or of a pool's worker), and
    renders needing a new path are stopped before the table runs out. A
    `Typsty.Pool` replaces a worker whose table is nearly full.
