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
- [Assigns](#assigns)
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

Typsty compiles documents with Typst 0.15 through a Rust NIF, which is
downloaded precompiled for your platform, so you don't need Rust installed. The
download is about 40 MB (82 MB unpacked, in `priv/native`), since it has both
the NIF and the program `Typsty.Pool` runs, which each include Typst and its
fonts.

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

    = Invoice #assigns.number

    Billed to #assigns.customer.name on #assigns.issued_on.display("[month repr:long] [day], [year]").

    #table(
      columns: (1fr, auto),
      [*Item*], [*Price*],
      ..assigns.items.map(item => (item.name, [\$#item.price])).flatten(),
    )

    *Total: \$#assigns.items.map(item => item.price).sum()*
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

files = %{"logo.png" => File.read!(Application.app_dir(:my_app, "priv/static/images/logo.png"))}

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
{:ok, pdf} = Typsty.to_pdf("= Hello #assigns.name", %{name: "World"})
{:ok, [page]} = Typsty.to_png("= Hello #assigns.name", %{name: "World"}, ppi: 300)
```

The assigns are always a map, and the options come after them.

## Assigns

The template reads the assigns from a dictionary named `assigns`, the way a
LiveView's `@number` is `assigns.number`: `assigns.number`, `assigns.customer`
and `assigns.items` above. You can tell at a glance what came from Elixir and
what the template defines, and an assign can't shadow anything in Typst (an
assign named `title` is `assigns.title`, and `title` is still Typst's). Typst
gets the data itself rather than code generated from it, so nothing needs
escaping, and the template can loop over lists, read fields, do arithmetic and
format dates:

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
| `MapSet`, `Range`                                | `array`                                     |
| other structs                                    | see `Typsty.Encoder`                        |

The assigns are a map with atom or string keys. A template reads keys that
aren't Typst identifiers with `at` (`assigns.at("invoice number")`), and assigns
that may be missing with a default:

```typst
#let subtitle = assigns.at("subtitle", default: none)
```

Keyword lists are lists of tuples, so they become arrays of pairs: pass maps for
dictionaries. Typst's datetimes have no time zone or fractions of a second, so
a `DateTime` keeps its wall time and times are truncated to the second, and its
decimals have 28 significant digits.

Other structs are passed when they implement `Typsty.Encoder`, so that their
internal fields (an Ecto schema's metadata, or a password hash) don't reach
templates by accident. Derive it to pass a struct as a dictionary of its
fields, or some of them:

```elixir
defmodule MyApp.Customer do
  @derive {Typsty.Encoder, only: [:name, :email]}
  defstruct [:name, :email, :password_hash]
end
```

or implement it to pass a struct differently:

```elixir
defimpl Typsty.Encoder, for: MyApp.Money do
  def encode(money), do: MyApp.Money.to_string(money)
end
```

A template that uses a few assigns a lot can give them short names, by
destructuring them at its top. The names are then the template's own, so pick
ones that don't hide anything it uses from Typst, such as `title` or `page`:

```typst
#let (customer, items) = assigns

= Invoice for #customer.name
```

`assigns` is bound at the top of the template, like a `#let` binding, so it's
only visible in the template itself. Pass the files it imports, such as
components, the values they need as arguments, which keeps them independent of
where their data comes from:

```typst
// components.typ
#let line-items(items) = table(
  columns: 2,
  ..items.map(item => (item.name, [#item.price])).flatten(),
)
```

```typst
#import "components.typ": line-items
#line-items(assigns.items)
```

(Imported files can also read the assigns from `sys.inputs.assigns`.)

`render/1` gets the assigns first, so it can compute values for the template
with all of Elixir:

```elixir
def render(assigns) do
  assigns = Map.put(assigns, :due_on, Date.add(assigns.issued_on, 30))

  ~TYPST"""
  Due on #assigns.due_on.display()
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
    "components.typ" => File.read!(Application.app_dir(:my_app, "priv/typst/components.typ"))
  }
)
```

```typst
#import "components.typ": callout
#image("charts/revenue.svg")
#let sales = csv("data/sales.csv")
```

Name files yourself, rather than with names that come from users (an upload's
file name, say): a `.typ` file in `:files` takes the place of the one the
template imports, which would let a user run their own Typst code. Use names
like `uploads/#{id}.png`.

Without the `:root` option, a document can only read the files it's given. Set
`:root` to a directory to also read files from it (files in `:files` take
precedence). Documents can't read outside it, even through symbolic links, and
may read files of up to 512 MiB from it. `main.typ` is the template itself.

Typst keeps every file path it has seen for the life of the VM, and has room for
65,535 of them, so use stable names like `logo.png` rather than a new unique
name for every render; a template that builds paths from data, like
`image("photos/" + assigns.id)`, uses a new one for every id. Typsty stops a
render that reads more than 10,000 different files, refuses new names in
`:files` once 50,000 different ones have been given over the life of the VM,
and stops renders that need a new path once the table is nearly full, rather
than let it overflow; inside
the VM, that lasts until the VM restarts, while a `Typsty.Pool` replaces its
workers. Typst keeps label names and bibliography keys for the life of the VM
too, so make labels from fixed names (`<total>`), not from data such as ids.

Renders inside the VM can't read PDF files (to use a PDF as an image, say), or
SVG images that contain other SVG images, since decoding them can crash the VM.
Renders in a `Typsty.Pool` can.

## Fonts

Documents can use the fonts installed on the system, the fonts that come with
Typst (Libertinus Serif, New Computer Modern, New Computer Modern Math and
DejaVu Sans Mono), and fonts in the directories given with `:font_paths`. For
documents that render the same on every machine, ship your fonts with your
application and turn system fonts off:

```elixir
# config/runtime.exs
config :typsty, font_paths: [Application.app_dir(:my_app, "priv/fonts")], system_fonts: false
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

Downloaded 2 of 2 packages into priv/typst/packages. Templates can import them when the :package_paths option includes that directory, in config/runtime.exs:

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

Errors that depend on the data, such as a missing assign or a value of the
wrong type, are returned as a `Typsty.RenderError` with the diagnostics Typst
reported, pointing at the line in your module or `.typ` file, with hints:

```elixir
{:error, %Typsty.RenderError{reason: :typst} = error} = MyApp.Invoice.to_pdf(%{number: 1042}, files: files)
Exception.message(error)
#=> failed to render the Typst document:
#=>
#=> lib/my_app/invoice.ex:11:24: dictionary does not contain key "customer"
#=>   hint: there's no "customer" in the assigns. Pass it from Elixir, or read it with `assigns.at("customer", default: none)` if it's optional
```

The error's `:reason` tells Typst's errors (`:typst`) apart from renders that
timed out (`:timeout`) or couldn't start in time because the server was busy
(`:busy`), so a web application can answer those with a 503 and a retry. See
`Typsty.RenderError` for the others. Invalid arguments, such as an unknown
option or a value that can't be passed to Typst, raise an `ArgumentError`.

Typst's warnings, such as an unknown font family, are logged. Every render also
emits [telemetry](https://hexdocs.pm/telemetry) events (see `Typsty.Telemetry`).

Errors are written for developers: their messages can quote the assigns, and
name paths on the server (the `:root` directory's, say). Log them, and show
users a message of your own.

## Running Typst inside the BEAM

Typsty runs Typst in a NIF, inside your VM, so a crash in it would take the
whole VM down. It's built to protect the VM from what you render with:

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
  value it depended on is the same in the new render. (So it mostly helps
  renders with the same assigns: with new ones, the template and the files it
  imports are evaluated again, though fonts and images are loaded once.)
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
- **Assigns are data, never code.** They're converted to Typst values, nested
  at most 256 levels deep, with numbers and dates checked against what Typst
  can hold, and are shown as they are: a template can't do anything with them
  that it couldn't do with values it wrote itself. Links can only go to http,
  https, mailto and tel URLs (or relative ones): a link to another kind, such
  as a `javascript:` URL from a user, is left out of PDFs and SVGs, with a
  warning.
- **Files are checked before Typst decodes them**, for the files known to
  crash or hang its decoders: images whose header claims more than 134
  megapixels (a small file can claim to be enormous), including images inside
  SVGs; SVG and XML files nested more than 1,024 levels deep; compressed SVGs
  that expand past 128 MiB; SVGs with content far outside their canvas; XML
  entities that nest or expand past 16 MiB; PNG color profiles that expand past
  16 MiB; images without pixels; CBOR that declares more items than it holds;
  deeply nested bibliographies, and BibTeX references that cycle or expand
  exponentially; PDF files. Files are only read from `:root` and package
  directories if they are
  regular files inside them, so a symbolic link can't lead elsewhere, and a
  link to `/dev/zero` or a FIFO can't hang a render.
- **PNG export is checked before rasterizing.** A page, and the images,
  gradients and tilings on it, may use at most 2^28 pixels of textures (1 GiB),
  so an extreme `:ppi` or content far larger than the page returns an error
  instead of an allocation that would fail, and content placed far off the
  page (which takes minutes to draw) is an error too.
- **File paths are rationed**, since Typst keeps every path it sees for the
  life of the VM and breaks for good after 65,535 of them (see [Files](#files)).

Typst decodes many formats, with many libraries, and the checks can't promise
to catch every hostile file. **Render documents that read files from people
you don't trust, such as uploads, in a `Typsty.Pool` with a `:memory_limit`.**
Only the files a document reads are checked: data a template turns into bytes
itself (`image(bytes(assigns.svg))`, or bytes from a list of integers) isn't,
so pass such data as a file. An SVG
can read other files in the project by linking them, so don't give documents a
`:root` that holds other people's files.

A template, though, is code. Like any code, it can loop for a long time, and
it can ask for as much memory as it likes. An allocation that fails ends the VM
at once, whatever memory is free (a template that asks for an exabyte doesn't
wait for the machine to run out), and some of Typst's libraries end the process
on a panic in the middle of drawing. Typsty can't stop all of that inside the
VM. What a template does with its data decides how much work it does:

- `"x" * assigns.n`, `range(assigns.n)`, `table(columns: assigns.n)`,
  `heading(level: assigns.n)` and `lorem(assigns.n)` take as much memory or
  time as the number says.
- Numbering a huge number with Roman numerals or symbols
  (`numbering("I", assigns.n)`, or a counter or `enum(start: ...)` set from the
  data) writes a symbol for every thousand.
- A value of the wrong type changes what an operation does: an invoice line's
  `#(item.qty * item.price)` repeats a string when a user sends `"AAAAA"` as
  the quantity, as many times as the price says.
- Syntax highlighting a long text (`raw(assigns.code, lang: "js")`) takes time
  that grows faster than its length, which can't be cancelled.

### Which to use

Rendering inside the VM is the right choice for data that's well validated:
data your application built itself, or that came from users through an Ecto
changeset that cast its types and checked its sizes (`validate_number/3`,
`validate_length/3`) before it was saved to your database.

**Favor a `Typsty.Pool` with a `:memory_limit` for input from untrusted users
that isn't well validated**, such as request parameters passed to a template
as they are, or uploaded files, and for templates you don't write. In a pool,
the worst a render can do is end its worker: the render returns an error, and
the worker is replaced.

## Rendering in separate processes

`Typsty.Pool` runs renders in a pool of separate OS processes, which it can end
at any moment. It's the way to render input from untrusted users that isn't
well validated (see [Which to use](#which-to-use)), since it gives you
guarantees the NIF can't:

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
before or during a render returns an error to the process waiting for it. A
new worker loads the fonts renders use by default before it takes renders.

The pool isolates crashes and memory use, not privileges: its workers run as
the same user as the VM. They get only the environment variables that finding
fonts needs, not the VM's (such as secrets in `DATABASE_URL`).

The memory limit counts everything a worker allocates, including the fonts it
has loaded and Typst's caches, and each worker keeps its own, so leave room for
them; see `Typsty.Pool`. Without a memory limit, a render that allocates
without bound can make the system run out of memory, and the system may then
end the BEAM rather than the worker.

The pool's workers run `typsty_worker`, a program built from the same code as
the NIF, which comes with it. Rendering in a worker copies the template, the
assigns, the files and the output between processes, and a worker that
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
  # Renders inside the VM at once; defaults to the number of dirty CPU schedulers
  max_concurrent_renders: 8,
  log_warnings: true,
  # Packages for mix typsty.packages.get to fetch (see Packages)
  packages: []
```

Options are checked with [NimbleOptions](https://hex.pm/packages/nimble_options),
in the config as well as in calls: an invalid value, or an unknown option (a
typo such as `font_path`), raises an `ArgumentError` that names the option, and
says when it comes from the config. See `Typsty` for each option.

Paths are expanded relative to the current directory when a document renders,
so in a release, set them in `config/runtime.exs` with `Application.app_dir/2`:

```elixir
config :typsty, font_paths: [Application.app_dir(:my_app, "priv/fonts")]
```

`:pdf_standards` takes Typst's standard names, such as `"a-2b"` for PDF/A-2b
and `"ua-1"` for PDF/UA-1. PDF/A needs the document's creation date, which is
the time of the render unless the template sets `#set document(date: ...)`.

`datetime.today()` is the date in UTC. For a date in the user's time zone, pass
it as an assign.

## Building the NIF from source

The NIF is downloaded precompiled for macOS (Apple Silicon and Intel), Linux
(x86-64 and ARM64, glibc and musl) and Windows (x86-64); `Typsty.Pool` is less
tested on Windows than on macOS and Linux. On Alpine Linux, the NIF needs
`libgcc` (`apk add libgcc`, which `libstdc++` brings along). To build it from
source instead, install [Rust](https://www.rust-lang.org/tools/install) 1.92 or
later, add Rustler to your dependencies:

```elixir
{:rustler, ">= 0.0.0", optional: true}
```

and set `TYPSTY_BUILD=1` when compiling:

```shell
TYPSTY_BUILD=1 mix deps.compile typsty --force --include-children
```

or, to always build it from source, configure RustlerPrecompiled:

```elixir
config :rustler_precompiled, :force_build, typsty: true
```

Development versions of Typsty (such as a Git dependency on `master`) are always
built from source, so they need Rust and the Rustler dependency too, as does a
Git dependency on a release's tag (with `TYPSTY_BUILD=1`).

If downloading the precompiled NIF fails with a TLS error such as
`unsupported_certificate`, update Erlang/OTP: some patch releases (such as
27.2) don't accept the certificates GitHub's downloads use. Building from
source works too.

## Attribution

- [Typst](https://github.com/typst/typst), the typesetting system Typsty is a
  wrapper for (Apache License 2.0)
- [typstyle](https://github.com/typstyle-rs/typstyle), the Typst formatter
  behind `Typsty.Formatter` (Apache License 2.0)
- The precompiled NIF and worker include the fonts that come with Typst,
  through [typst-assets](https://github.com/typst/typst-assets), and many Rust
  crates, under their own licenses: see
  [THIRD_PARTY_NOTICES.txt](https://github.com/akoutmos/typsty/blob/master/THIRD_PARTY_NOTICES.txt), which is also in
  `priv/native`, as `typsty-THIRD_PARTY_NOTICES.txt`
- The Elixir [typst](https://hex.pm/packages/typst) and
  [typster](https://hex.pm/packages/typster) packages, whose virtual file system
  and variables inspired Typsty's
