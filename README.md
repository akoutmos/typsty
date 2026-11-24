# Typsty

<p align="center">
  Render <a href="https://typst.app" target="_blank">Typst</a> documents to PDF, PNG and SVG right from Elixir!
</p>

<p align="center">
  <a href="https://hex.pm/packages/typsty">
    <img alt="Hex.pm" src="https://img.shields.io/hexpm/v/typsty?style=for-the-badge">
  </a>

<a href="https://github.com/akoutmos/typsty/actions">
    <img alt="GitHub Workflow Status (master)"
    src="https://img.shields.io/github/actions/workflow/status/akoutmos/typsty/main.yml?label=Build%20Status&style=for-the-badge&branch=master">
  </a>

<a href="https://coveralls.io/github/akoutmos/typsty?branch=master">
    <img alt="Coveralls master branch" src="https://img.shields.io/coveralls/github/akoutmos/typsty/master?style=for-the-badge">
  </a>

<a href="https://github.com/sponsors/akoutmos">
    <img alt="Support the project" src="https://img.shields.io/badge/Support%20the%20project-%E2%9D%A4-lightblue?style=for-the-badge">
  </a>
</p>

<br>

## Contents

- [Installation](#installation)
- [Level Up Your Elixir Skills!](#level-up-your-elixir-skills)
- [Using Typsty](#using-typsty)
- [Variables](#variables)
- [Files](#files)
- [Fonts](#fonts)
- [Packages](#packages)
- [Errors](#errors)
- [Running Typst inside the BEAM](#running-typst-inside-the-beam)
- [Rendering in separate processes](#rendering-in-separate-processes)
- [Formatting](#formatting)
- [Configuration](#configuration)
- [Building the NIF from source](#building-the-nif-from-source)
- [Attribution](#attribution)

## Installation

[Available in Hex](https://hex.pm/packages/typsty), the package can be installed
by adding `typsty` to your list of dependencies in `mix.exs`. It requires Elixir
1.18 or later.

```elixir
def deps do
  [
    {:typsty, "~> 0.1.0"}
  ]
end
```

Typsty compiles documents with the Typst compiler through a Rust NIF, which is
downloaded precompiled for your platform, so you don't need Rust installed.

Documentation can be found at [https://hexdocs.pm/typsty](https://hexdocs.pm/typsty).

## Level Up Your Elixir Skills!

Everything I have learned building production Elixir systems ends up in one of
two places: an open source library on [Hex](https://hex.pm/users/akoutmos), or a
book. The libraries are free and will stay that way. The books are what let me
keep writing them.

If this library has been useful to you, picking up one of my books is the best
way to support this library and the many others that I maintain. You'll also
gain knowledge that took me years to attain!

<p align="center">
  <a target="_blank" href="https://financialelixir.dev"><img src="images/elixir_for_finance.png" width="180" /></a>
  <a target="_blank" href="https://elixirpatterns.dev"><img src="images/elixir_patterns.png" width="180" /></a>
  <a target="_blank" href="https://programmingnerves.dev"><img src="images/programming_nerves.png" width="180" /></a>
  <a target="_blank" href="https://pragprog.com/titles/passweather/build-a-weather-station-with-elixir-and-nerves"><img
  src="images/weather_station.png" width="180" /></a>
</p>

**[Elixir For Finance](https://www.financialelixir.dev)** — Learn how to
navigate markets and trading without leaving the BEAM. Livebook for exploration,
Explorer for dataframes, VegaLite for visualizations. This book goes through it
all!

**[Elixir Patterns](https://elixirpatterns.dev)** — The essential BEAM handbook
for the busy developer. The patterns and mental models covered in this book
teach you how to build scalable systems that can handle whatever production
throw at them.

**[Programming Nerves](https://www.programmingnerves.dev/)** — The best place to
start if you are looking to get your own hardware projects up and running with
Elixir and Nerves. I doubt you'll find a more fun and enjoyable hardware book
out there!

**[Build a Weather Station with Elixir and Nerves](https://pragprog.com/titles/passweather/build-a-weather-station-with-elixir-and-nerves/)**
— A project-based introduction to Nerves. Wire up the sensors, capture readings
and then pipe the data into a time series database that can be visualized with
Grafana.

## Using Typsty

A document module does `use Typsty` and defines `render/1` with the `~TYPST`
sigil, like a LiveView:

```elixir
defmodule MyApp.Invoice do
  use Typsty

  def render(assigns) do
    ~TYPST"""
    #set page(paper: "us-letter")
    #image("logo.png", width: 3cm)

    = Invoice #number

    Billed to #customer.name on #issued_on.display("[month repr:long] [day], [year]").

    #table(
      columns: (1fr, auto),
      [*Item*], [*Price*],
      ..items.map(item => (item.name, [\$#item.price])).flatten(),
    )

    *Total: \$#items.map(item => item.price).sum()*
    """
  end
end
```

Or it leaves `render/1` out and keeps the template in a `.typ` file next to the
module, with the same base name (`invoice.ex` and `invoice.typ`), like
LiveView's colocated templates, which lets editors that know Typst highlight
it.

Render it to PDF, PNG (one image per page) or SVG (one per page):

```elixir
assigns = %{
  number: 1042,
  issued_on: ~D[2026-11-23],
  customer: %{name: "Acme Corp"},
  items: [%{name: "Widget", price: Decimal.new("19.99")}, %{name: "Gadget", price: Decimal.new("5.01")}]
}

files = %{"logo.png" => File.read!("priv/static/images/logo.png")}

{:ok, pdf} = MyApp.Invoice.to_pdf(assigns, files: files)
{:ok, [first_page | _]} = MyApp.Invoice.to_png(assigns, files: files, ppi: 300)
{:ok, svgs} = MyApp.Invoice.to_svg(assigns, files: files)
```

Each one has a bang variant (`to_pdf!/2` and so on) that raises instead of
returning an error.

Templates are checked when your code compiles: a syntax error in a `~TYPST`
sigil or a `.typ` template fails the build, pointing at the line in your file.

For templates that don't live in a module, such as ones stored in a database,
render a string of Typst source with `Typsty.to_pdf/3`, `Typsty.to_png/3` and
`Typsty.to_svg/3`, and check it with `Typsty.validate/1`:

```elixir
{:ok, pdf} = Typsty.to_pdf("= Hello #name", %{name: "World"})
{:ok, [page]} = Typsty.to_png("= Hello #name", %{name: "World"}, ppi: 300)
```

The assigns are always a map, and the options come after them.

## Variables

The assigns become regular Typst variables in the template: `number`, `customer`
and `items` above. Typst gets the data itself rather than code generated from
it, so nothing needs escaping, and the template can loop over lists, read
fields, do arithmetic and format dates:

| Elixir                                           | Typst                                       |
| ------------------------------------------------ | ------------------------------------------- |
| `nil`, `true`, `false`                           | `none`, `true`, `false`                     |
| integers and floats                              | `int` (64-bit) and `float`                  |
| strings                                          | `str`                                       |
| atoms                                            | `str` (`:paid` becomes `"paid"`)            |
| lists and tuples                                 | `array`                                     |
| maps                                             | `dictionary`, with string keys, sorted      |
| `Date`, `Time`, `NaiveDateTime`, `DateTime`      | `datetime` (`DateTime` keeps its wall time) |
| `Decimal`                                        | `decimal`                                   |
| other structs                                    | `dictionary`, or see `Typsty.Encoder`       |

Keyword lists are lists of tuples, so they become arrays of pairs: pass maps for
dictionaries. Typst's datetimes have no time zone or fractions of a second, so
a `DateTime` keeps its wall time and times are truncated to the second, and its
decimals have 28 significant digits.

Implement `Typsty.Encoder` to pass your own structs differently:

```elixir
defimpl Typsty.Encoder, for: MyApp.Money do
  def encode(money), do: MyApp.Money.to_string(money)
end
```

The variables are bound at the top of the template, like `#let` bindings, so
they're only visible in the template itself. A variable named after something in
Typst's standard library (such as `title`) shadows it there, but not in imported
files and packages, and `std.title` still reaches the original (unless a
variable is named `std`). Other files can
read the variables from `sys.inputs`, which is also how a template can make one
optional:

```typst
#let subtitle = sys.inputs.at("subtitle", default: none)
```

`render/1` gets the assigns first, so it can compute values for the template
with all of Elixir:

```elixir
def render(assigns) do
  assigns = Map.put(assigns, :due_on, Date.add(assigns.issued_on, 30))

  ~TYPST"""
  Due on #due_on.display()
  """
end
```

## Files

Images, data files and other `.typ` files are passed as binaries in the
`:files` option. They live in a virtual file system for the render and are never
written to disk:

```elixir
MyApp.Report.to_pdf(assigns,
  files: %{
    "logo.png" => logo,
    "charts/revenue.svg" => chart_svg,
    "data/sales.csv" => csv,
    "components.typ" => File.read!("priv/typst/components.typ")
  }
)
```

```typst
#import "components.typ": callout
#image("charts/revenue.svg")
#let sales = csv("data/sales.csv")
```

Without the `:root` option, a document can only read the files it's given. Set
`:root` to a directory to also read files from it (files in `:files` take
precedence). Documents can't read outside it, even through symbolic links.

Typst keeps every file path it has seen for the life of the VM, and has room for
65,535 of them, so use stable names like `logo.png` or `photos/42.jpg` rather
than a new unique name for every render. Typsty stops a render that reads more
than 10,000 different files, refuses new paths in `:files` after 50,000 have
been given, and stops renders that need a new path once the table is nearly
full, rather than let it overflow. Typst keeps label names for the life of the
VM too, so make labels from fixed names (`<total>`), not from data such as ids.

Renders inside the VM can't read PDF files (to use a PDF as an image, say),
since a malformed PDF can crash the VM. Renders in a `Typsty.Pool` can.

## Fonts

Documents can use the fonts installed on the system, the fonts that come with
Typst (Libertinus Serif, New Computer Modern, New Computer Modern Math and
DejaVu Sans Mono), and fonts in the directories given with `:font_paths`. For
documents that render the same on every machine, ship your fonts with your
application and turn system fonts off:

```elixir
config :typsty, font_paths: ["priv/fonts"], system_fonts: false
```

Fonts are scanned once for each combination of font options and cached for the
life of the VM. Font files are only read the first time a document uses them.
To scan them ahead of the first render, call `Typsty.font_families/1` when your
application starts. It also returns the font families that were found, which
helps when a font isn't being picked up.

## Packages

Templates can import [Typst packages](https://typst.app/universe). Download them
into your project with `mix typsty.packages.get`:

```shell
mix typsty.packages.get @preview/cetz:0.4.2
```

```
* Fetched @preview/cetz:0.4.2
* Fetched @preview/oxifmt:1.0.0 (imported by @preview/cetz:0.4.2)

Downloaded 2 of 2 packages into priv/typst/packages. Templates can import them when the :package_paths option includes that directory:

    config :typsty, package_paths: [Application.app_dir(:my_app, "priv/typst/packages")]
```

Packages are saved in `priv/typst/packages` (change it with `--path`), laid out
as `namespace/name/version` like Typst's own package directories, so they ship
with your releases. Packages that a package imports are fetched too, and a
package given without a version (`@preview/cetz`) gets its latest version that
works with the Typst version Typsty uses (`Typsty.typst_version/0`).

Point the `:package_paths` option at the directory, in `config/runtime.exs`:

```elixir
config :typsty, package_paths: [Application.app_dir(:my_app, "priv/typst/packages")]
```

```typst
#import "@preview/cetz:0.4.2": canvas, draw
```

To keep the list of packages in your repository, for CI and Docker builds, list
them in your config, with their versions, and run the task without arguments
(in a Docker build, in the build stage, before `mix release`):

```elixir
# config/config.exs
config :typsty, packages: ["@preview/cetz:0.4.2"]
```

Typsty never downloads packages while rendering, so documents don't wait on the
network and always use the package versions you ship. A template that imports a
package that isn't there fails with an error that says which package to fetch
and which directories were searched. Your own packages can go in the same
directories, under a namespace such as `local`.

## Errors

A syntax error fails the build with a `Typsty.SyntaxError`:

```
** (Typsty.SyntaxError) invalid Typst syntax: lib/my_app/invoice.ex:12:18: unclosed delimiter

    #let total = (1, 2
                 ^
```

Errors that depend on the data, such as a missing variable or a value of the
wrong type, are returned as a `Typsty.RenderError` with the diagnostics Typst
reported, pointing at the line in your module or `.typ` file:

```elixir
{:error, %Typsty.RenderError{reason: :typst} = error} = MyApp.Invoice.to_pdf(%{number: 1042}, files: files)
Exception.message(error)
#=> failed to render the Typst document:
#=>
#=> lib/my_app/invoice.ex:11:16: unknown variable: customer
```

The error's `:reason` tells Typst's errors (`:typst`) apart from renders that
timed out (`:timeout`) or couldn't start in time because the server was busy
(`:busy`), so a web application can answer those with a 503 and a retry. See
`Typsty.RenderError` for the others. Invalid arguments, such as an unknown
option or a value that can't be passed to Typst, raise an `ArgumentError`.

Typst's warnings, such as an unknown font family, are logged. Every render also
emits [telemetry](https://hexdocs.pm/telemetry) events (see `Typsty.Telemetry`).

## Running Typst inside the BEAM

Typsty runs Typst in a NIF, inside your VM, so a crash in it would take the
whole VM down. It's built so that the data you render with can't crash it:

- **Renders don't hold up the VM.** Each render runs on a thread of its own,
  outside the BEAM's schedulers, and the process that asked for it waits for a
  message, like any other. The thread has a 256 MiB stack (reserved address
  space, not memory), as does Typst's thread pool, so deeply nested content
  can't overflow a stack, panics in Typst are returned as a
  `Typsty.RenderError`, and Typst's own limits (parsing, call and layout depth)
  get a chance to stop runaway recursion.
- **Renders are independent.** Concurrent renders of the same template, with
  the same file names and assigns names but different values (as a Phoenix
  controller does for each request), each produce exactly what they would on
  their own. Typst's cache only reuses work after checking that every file and
  value it depended on is the same in the new render.
- **Renders time out** after 60 seconds by default (`:timeout`). A render that
  times out returns an error and is cancelled: it unwinds the next time Typst
  lays out content, loads a file or font, or exports a PNG or SVG page, which
  for most documents is within milliseconds. A render is cancelled too when the
  process waiting for it exits. A thread can't be killed safely, so a template
  doing pure computation (a long loop of arithmetic) keeps running until it
  gets to one of those points.
- **Renders are limited** to `:max_concurrent_renders` at once (by default, one
  per CPU core), counting renders that timed out and are still being
  cancelled. New renders wait for a slot within their timeout, so renders that
  keep timing out can't pile up in the background. `Typsty.running_renders/0`
  reports how many are running.
- **Data is checked before Typst gets it.** Variables can be nested at most
  256 levels deep. Images whose header claims more than 134 megapixels are
  refused before they're decoded (a small file can claim to be enormous), as
  are SVG and XML files nested more than 1,024 levels deep, compressed SVGs
  that expand past 128 MiB, XML entities that nest or expand past 16 MiB, and
  PDF files. Files are only read from `:root` and package directories if they
  are regular files inside them, so a symbolic link can't lead elsewhere, and
  a link to `/dev/zero` or a FIFO can't hang a render.
- **PNG export is checked before rasterizing.** A page, and the images,
  gradients and tilings on it, may use at most 2^28 pixels of textures (1 GiB),
  so an extreme `:ppi` or content far larger than the page returns an error
  instead of an allocation that would fail.
- **File paths are rationed**, since Typst keeps every path it sees for the
  life of the VM and breaks for good after 65,535 of them (see [Files](#files)).

A template, though, is code. Like any code, it can loop for a long time, and
it can ask for as much memory as it likes (`range(n)`, `"x" * n`, and so on).
An allocation that fails ends the VM at once, whatever memory is free: a
template that asks for an exabyte doesn't wait for the machine to run out.
Typsty can't stop that inside the VM. Render templates you don't write, or
ones that use data to decide how much work to do, in separate processes.

## Rendering in separate processes

`Typsty.Pool` runs renders in a pool of separate OS processes, which it can end
at any moment. That gives you guarantees the NIF can't:

- A render that runs past its timeout is **stopped right away**, whatever it's
  doing, including pure computation.
- A render can be given a **memory limit**, and is stopped when it goes over it.
- A worker that crashes, for any reason, takes **nothing else down**.

Add a pool to your supervision tree, and render with it:

```elixir
children = [
  {Typsty.Pool, name: MyApp.TypstPool, size: 4, memory_limit: 1_000_000_000}
]
```

```elixir
MyApp.Invoice.to_pdf(assigns, pool: MyApp.TypstPool, timeout: 10_000)
```

Or render every document with it:

```elixir
config :typsty, pool: MyApp.TypstPool
```

Renders return what they return without a pool: the same output and the same
warnings and errors, pointing at the same lines (and they can read PDF files).
A worker that's stopped is replaced, and workers end when the pool stops, when
the process rendering with them exits and when the VM exits. A pool that stops
during a render returns an error to the process waiting for it.

The memory limit counts everything a worker allocates, including the fonts it
has loaded and Typst's caches, and each worker keeps its own, so leave room for
them; see `Typsty.Pool`.

The pool's workers run `typsty_worker`, a program built from the same code as
the NIF, which comes with it. Rendering in a worker copies the template, the
variables, the files and the output between processes, and a worker that
replaces one that was stopped starts with empty caches, so it's a little
slower than the NIF. See `Typsty.Pool` for its options.

## Formatting

`Typsty.Formatter` is a `mix format` plugin that formats `~TYPST` sigils and
`.typ` files with [typstyle](https://github.com/typstyle-rs/typstyle). Add it to
your `.formatter.exs`:

```elixir
[
  plugins: [Typsty.Formatter],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs,typ}"]
]
```

To leave a sigil as it is, use the `noformat` modifier:
`~TYPST"""..."""noformat`. See `Typsty.Formatter` for its options.

## Configuration

Every rendering option except `:files` can be set in your application config,
as a default for every render:

```elixir
config :typsty,
  root: nil,
  font_paths: [],
  system_fonts: true,
  embedded_fonts: true,
  package_paths: [],
  ppi: 144,
  pdf_standards: [],
  timeout: 60_000,
  pool: nil,
  # Renders inside the VM at once (by default, the number of dirty CPU schedulers)
  max_concurrent_renders: :erlang.system_info(:dirty_cpu_schedulers),
  log_warnings: true,
  # Packages for mix typsty.packages.get to fetch (see Packages)
  packages: []
```

Paths are expanded relative to the current directory when a document renders,
so in a release, set them in `config/runtime.exs` with `Application.app_dir/2`:

```elixir
config :typsty, font_paths: [Application.app_dir(:my_app, "priv/fonts")]
```

`:pdf_standards` takes Typst's standard names, such as `"a-2b"` for PDF/A-2b
and `"ua-1"` for PDF/UA-1. PDF/A needs the document's creation date, which is
the time of the render unless the template sets `#set document(date: ...)`.

## Building the NIF from source

The NIF is downloaded precompiled for macOS (Apple Silicon and Intel), Linux
(x86-64 and ARM64, glibc and musl) and Windows (x86-64). To build it from
source instead, install [Rust](https://www.rust-lang.org/tools/install) 1.92 or
later, add Rustler to your dependencies:

```elixir
{:rustler, ">= 0.0.0", optional: true}
```

and set `TYPSTY_BUILD=1` when compiling:

```shell
TYPSTY_BUILD=1 mix deps.compile typsty --force
```

or, to always build it from source, configure RustlerPrecompiled:

```elixir
config :rustler_precompiled, :force_build, typsty: true
```

Development versions of Typsty (such as a Git dependency on `master`) are always
built from source, so they need Rust and the Rustler dependency too.

## Attribution

- [Typst](https://github.com/typst/typst), the typesetting system Typsty is a
  wrapper for (Apache License 2.0)
- [typstyle](https://github.com/typstyle-rs/typstyle), the Typst formatter
  behind `Typsty.Formatter` (Apache License 2.0)
- The precompiled NIF includes the fonts that come with Typst, through
  [typst-assets](https://github.com/typst/typst-assets), under their own
  licenses
- The Elixir [typst](https://hex.pm/packages/typst) and
  [typster](https://hex.pm/packages/typster) packages, whose virtual file system
  and variables inspired Typsty's
