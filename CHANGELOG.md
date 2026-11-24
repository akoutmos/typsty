# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Document modules with `use Typsty`: `render/1` with the `~TYPST` sigil, or a colocated `.typ` template (or one
  given with the `:template` option), and generated `to_pdf/2`, `to_png/2` and `to_svg/2`, with bang variants.
- `Typsty.to_pdf/3`, `Typsty.to_png/3` and `Typsty.to_svg/3` for templates and Typst source.
- Assigns become regular Typst variables in the template, passed as Typst values rather than generated code:
  strings, numbers, booleans, `nil`, lists, tuples, maps, dates and times, and decimals. Structs are passed as
  dictionaries, or as `Typsty.Encoder` encodes them.
- A virtual file system: images, data files and `.typ` files are passed as binaries with the `:files` option. Files
  can also be read from a `:root` directory.
- Fonts from the system, from Typst's embedded fonts and from `:font_paths`, scanned once per font configuration and
  cached. `Typsty.font_families/1` lists the font families and warms the cache.
- Typst packages from local `:package_paths` directories.
- Template syntax checked at compile time, with `Typsty.SyntaxError` pointing at the line and column in the module or
  `.typ` file. `Typsty.validate/1` checks Typst source at runtime.
- `Typsty.RenderError` with Typst's diagnostics (message, hints, location and trace), mapped to the lines of the
  module or `.typ` file. Typst's warnings are logged.
- `Typsty.Formatter`, a `mix format` plugin for `~TYPST` sigils and `.typ` files, using typstyle. `Typsty.format/2`
  formats Typst source.
- PDF standards (such as PDF/A-2b and PDF/UA-1) with the `:pdf_standards` option, and the PNG resolution with `:ppi`.
- Telemetry events for every render.
- Precompiled NIFs for macOS, Linux (glibc and musl) and Windows, with RustlerPrecompiled.
