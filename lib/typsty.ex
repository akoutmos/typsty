defmodule Typsty do
  @moduledoc """
  Render [Typst](https://typst.app) documents to PDF, PNG and SVG, with Elixir data passed
  to the template as Typst values, in its `assigns` dictionary.

  ## Document modules

  A document module does `use Typsty` and either defines `render/1` with the `~TYPST` sigil:

  ```elixir
  defmodule MyApp.Invoice do
    use Typsty

    def render(assigns) do
      ~TYPST\"\"\"
      #set page(paper: "us-letter")

      = Invoice #assigns.number

      #table(
        columns: (1fr, auto),
        [*Item*], [*Price*],
        ..assigns.items.map(item => (item.name, [\\$#item.price])).flatten(),
      )
      \"\"\"
    end
  end
  ```

  or leaves `render/1` out and puts the template in a `.typ` file next to the module, with
  the same base name (`invoice.ex` and `invoice.typ`), like LiveView's colocated templates.

  Render it with the generated functions:

  ```elixir
  assigns = %{number: 1042, items: [%{name: "Widget", price: 25}]}

  {:ok, pdf} = MyApp.Invoice.to_pdf(assigns)
  {:ok, [page_1 | _]} = MyApp.Invoice.to_png(assigns, ppi: 300)
  {:ok, pages} = MyApp.Invoice.to_svg(assigns)
  ```

  `to_pdf/2`, `to_png/2` and `to_svg/2` return `{:error, Typsty.RenderError.t()}` when the
  document fails to render, and their bang variants (`to_pdf!/2` and so on) raise it. They
  take the options described in [Options](#module-options).

  Templates are checked when the module compiles: a syntax error in a `~TYPST` sigil or a
  `.typ` template fails the build with a `Typsty.SyntaxError` that points at the line in
  your file. Run `mix format` with `Typsty.Formatter` to format them with
  [typstyle](https://github.com/typstyle-rs/typstyle).

  ## Assigns

  The template reads the assigns from a dictionary named `assigns`, like a LiveView's
  `@number` is `assigns.number`: `assigns.number` and `assigns.items` above. That keeps what
  comes from Elixir apart from what the template defines, and never shadows anything in
  Typst. Typst gets the data itself, not code generated from it, so nothing needs escaping,
  and the template can loop over lists, read fields and do arithmetic:

  | Elixir                                    | Typst                                  |
  | ----------------------------------------- | -------------------------------------- |
  | `nil`, `true`, `false`                    | `none`, `true`, `false`                |
  | integers and floats                       | `int` (64-bit) and `float`             |
  | strings                                   | `str`                                  |
  | atoms                                     | `str` (`:paid` becomes `"paid"`)       |
  | lists and tuples                          | `array`                                |
  | maps                                      | `dictionary`, with string keys         |
  | `Date`, `Time`, `NaiveDateTime`, `DateTime` | `datetime` (`DateTime` keeps its wall time) |
  | `Decimal`                                 | `decimal`                              |
  | `MapSet`, `Range`                         | `array`                                |
  | other structs                             | see `Typsty.Encoder`                   |

  The assigns are a map with atom or string keys, and the keys of maps inside the data can be
  atoms, strings or integers. A template reads keys that aren't identifiers with `at`
  (`assigns.at("invoice number")`), and assigns that may be missing with a default:

  ```typst
  #let subtitle = assigns.at("subtitle", default: none)
  ```

  A few things to know about the conversion:

  - Dictionaries are sorted by key, since Elixir maps have no order. The keys are strings, so
    integer keys sort as text (`"10"` before `"2"`).
  - Keyword lists are lists of tuples, so they become arrays of `(key, value)` pairs; pass
    maps for dictionaries. Charlists are lists of integers too.
  - Typst's datetimes have no fractions of a second or time zones: times are truncated to
    the second, and a `DateTime` keeps its wall time (convert it to the time zone the
    document should show first).
  - Typst's decimals have 28 significant digits, at most 28 of them after the decimal point.
  - Links can only go to http, https, mailto and tel URLs, or relative ones: a link to
    another kind of URL, such as a `javascript:` URL that came from a user, is left out of
    PDFs and SVGs, with a warning.
  - `datetime.today()` is the date in UTC: pass the date in the user's time zone as an
    assign instead.

  A template that uses a few assigns a lot can give them short names, by destructuring
  them at its top. The names are then the template's own, so pick ones that don't hide
  anything it uses from Typst, such as `title` or `page`:

  ```typst
  #let (customer, items) = assigns

  = Invoice for #customer.name
  ```

  `assigns` is bound at the top of the template, like a `let` binding, so it's only visible
  in the template itself. Pass the files it imports, such as components, the values they
  need as arguments, which keeps them independent of where their data comes from:

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

  `render/1` gets the assigns before the template does, so it can compute values for it:

  ```elixir
  def render(assigns) do
    assigns = Map.put(assigns, :total, Enum.sum_by(assigns.items, & &1.price))

    ~TYPST\"\"\"
    Total: #assigns.total
    \"\"\"
  end
  ```

  ## Files

  Files the document reads, such as images, data files and other `.typ` files, are passed
  with the `:files` option, as binaries. They're never written to disk:

  ```elixir
  MyApp.Invoice.to_pdf(assigns, files: %{"logo.png" => logo_png, "styles.typ" => styles})
  ```

  ```typst
  #import "styles.typ": heading-style
  #image("logo.png", width: 4cm)
  ```

  Paths are relative to the project root (`"logo.png"` and `"/logo.png"` are the same file),
  and `main.typ` is the template itself. To also read files from a directory, set `:root`;
  files given with `:files` take precedence. Without `:root`, the document can only read
  the files it's given. Files read from `:root` may be at most 512 MiB.

  Typst keeps every file path it sees for the life of the VM, and has room for 65,535 of
  them. Use stable names, like `logo.png` or `photos/1.jpg`, rather than a unique name per
  render: a template that builds paths from data (`image("photos/" + assigns.id)`) uses a new
  one for every id. Typsty stops a render that reads more than 10,000 different files, and
  stops renders that need a new path once Typst's table is nearly full, which inside the VM
  lasts until it restarts. A `Typsty.Pool` replaces a worker whose table is nearly full.
  Typst keeps label names and bibliography keys for the life of the VM too, so make labels
  from fixed names, not from data such as ids.

  Documents rendered inside the VM can't read PDF files (as images, for example), or SVG
  images that contain other SVG images: decoding them can crash the VM. Render them in a
  `Typsty.Pool`, which can.

  ## Options

  Rendering takes these options. All of them, except `:files`, can also be set in your
  application config, as defaults for every render:

  ```elixir
  # config/runtime.exs
  config :typsty, font_paths: [Application.app_dir(:my_app, "priv/fonts")], system_fonts: false
  ```

  #{Typsty.Options.docs(:render)}

  These can only be set in the application config:

  #{Typsty.Options.docs(:config)}

  Invalid options, in a call or in the config, raise `ArgumentError`, with a message that
  says which option is wrong.

  Renders run on threads of their own, outside the BEAM's schedulers, and the process that
  asked for the render waits for a message, so a render never holds up a scheduler.

  Fonts are scanned once for each combination of `:font_paths`, `:system_fonts` and
  `:embedded_fonts` and then cached, so only the first render with given font settings
  pays for scanning them. Call `font_families/1` when your application starts to scan them
  ahead of time. (A `Typsty.Pool` worker scans its own when it starts.)

  ## Errors

  The functions that render return `{:error, %Typsty.RenderError{}}` when the document can't
  be rendered, with a `:reason` that tells Typst's errors apart from timeouts and the like
  (see `Typsty.RenderError`). They raise `ArgumentError` for invalid arguments: invalid
  options, assigns that aren't a map, or data that can't be passed to Typst (see
  [Assigns](#module-assigns)).

  ## What a template can do

  Renders run with large stacks, away from the schedulers, and Typsty protects the VM from
  the data a document is rendered with:

  - **Assigns** are converted to Typst values, with limits on how deeply they nest and on
    the size of numbers and dates. They're data, never code: a template can't do anything
    with them that it couldn't do with values it wrote itself.
  - **Files** (in `:files`, or under `:root`) are checked before Typst decodes them, for the
    files known to crash or hang its decoders: images that claim to be enormous, compressed
    SVGs, XML entities and PNG color profiles that expand without bound, SVGs with content
    far outside their canvas, deeply nested XML, CBOR that declares billions of items,
    bibliographies whose references cycle or nest deeply, PDFs. Typst decodes many formats
    with many libraries, though, and the checks can't promise that every hostile file is
    caught.
    **Render documents that read files from people you don't trust, such as uploads, in a
    `Typsty.Pool` with a `:memory_limit`.** Only the files a document reads are checked:
    data a template turns into bytes itself (`image(bytes(assigns.svg))`) isn't, so pass
    such data as a file. An SVG can read other files in the project too, by linking them,
    so don't give documents a `:root` that holds other people's files.

  A template, though, is code. A template that loops forever is stopped at its timeout only
  when it next calls into Typst, and what it does with its data decides how much work it
  does: `"x" * assigns.n`, `range(assigns.n)` and `table(columns: assigns.n)` take as much
  memory as the number says, and an allocation that fails ends the VM. A value of the wrong
  type changes what an operation does, too: `#(item.qty * item.price)` repeats a string
  when a user sends one as the quantity.

  Rendering inside the VM is the right choice for well validated data: data your
  application built, or that came from users through an Ecto changeset that cast its types
  and checked its sizes. **Favor a `Typsty.Pool` with a `:memory_limit` for input from
  untrusted users that isn't well validated**, such as request parameters passed to a
  template as they are, and for templates you don't control: there, such a render only
  ends its worker.

  ## Warnings

  Typst's warnings (an unknown font family, for example) are logged with `Logger.warning/1`
  and included in the `:stop` telemetry event (see `Typsty.Telemetry`). To stop logging them:

  ```elixir
  config :typsty, log_warnings: false
  ```
  """

  require Logger

  alias Typsty.{Diagnostic, Native, Options, RenderError, SyntaxError, Template, Value}

  @template_extension ".typ"

  @typedoc "Assigns for a template: a map with atom or string keys."
  @type assigns :: map()

  @typedoc "A template: Typst source, or a template from the `~TYPST` sigil or `render/1`."
  @type template :: String.t() | Template.t()

  @typedoc "An option for rendering. See [Options](#module-options)."
  @type option :: unquote(Options.typespec(:render))

  @typedoc "An option for `format/2`."
  @type format_option :: unquote(Options.typespec(:format))

  @typedoc "An option for `font_families/1`: the font options for rendering."
  @type font_option :: unquote(Options.typespec(:fonts))

  @doc """
  Returns the template for the given assigns, as a `Typsty.Template` struct. Define it with
  the `~TYPST` sigil, or leave it out and put the template in a `.typ` file next to the
  module.
  """
  @callback render(assigns :: map()) :: Template.t()

  @doc """
  Makes the module a document module. See the module documentation.

  ## Options

  - `:template` - the template file, relative to the module's file. Defaults to the
    module's file name with the `.typ` extension. A module that defines `render/1` can't
    have a template.

  ## Overriding the generated functions

  `to_pdf/2`, `to_png/2` and `to_svg/2` are overridable, to give a module's renders default
  options, for example. Override them without default arguments, and call `super/2`; the
  versions with one argument and the bang variants call them, so they get the defaults too:

  ```elixir
  def to_pdf(assigns, opts) do
    super(assigns, Keyword.put_new(opts, :files, %{"logo.png" => MyApp.Assets.logo()}))
  end
  ```
  """
  defmacro __using__(opts) do
    opts = Keyword.validate!(opts, [:template])

    {template, explicit?} =
      case Keyword.fetch(opts, :template) do
        {:ok, path} when is_binary(path) ->
          {Path.expand(path, Path.dirname(__CALLER__.file)), true}

        {:ok, other} ->
          raise ArgumentError, "the :template option must be a path, got: #{Macro.to_string(other)}"

        :error ->
          {Path.rootname(__CALLER__.file) <> @template_extension, false}
      end

    quote do
      @behaviour Typsty

      import Typsty, only: [sigil_TYPST: 2]

      @__typsty_template__ {unquote(template), unquote(explicit?)}
      @before_compile Typsty

      @doc "Renders the document as a PDF. See `Typsty.to_pdf/3` for the options."
      @spec to_pdf(Typsty.assigns(), [Typsty.option()]) :: {:ok, binary()} | {:error, Typsty.RenderError.t()}
      def to_pdf(assigns, opts \\ []), do: Typsty.__render__(__MODULE__, :pdf, assigns, opts)

      @doc "Renders the document as a PDF, raising `Typsty.RenderError` if it fails."
      @spec to_pdf!(Typsty.assigns(), [Typsty.option()]) :: binary()
      def to_pdf!(assigns, opts \\ []), do: assigns |> to_pdf(opts) |> Typsty.__unwrap__!()

      @doc "Renders each page of the document as a PNG. See `Typsty.to_png/3` for the options."
      @spec to_png(Typsty.assigns(), [Typsty.option()]) :: {:ok, [binary()]} | {:error, Typsty.RenderError.t()}
      def to_png(assigns, opts \\ []), do: Typsty.__render__(__MODULE__, :png, assigns, opts)

      @doc "Renders each page of the document as a PNG, raising `Typsty.RenderError` if it fails."
      @spec to_png!(Typsty.assigns(), [Typsty.option()]) :: [binary()]
      def to_png!(assigns, opts \\ []), do: assigns |> to_png(opts) |> Typsty.__unwrap__!()

      @doc "Renders each page of the document as an SVG. See `Typsty.to_svg/3` for the options."
      @spec to_svg(Typsty.assigns(), [Typsty.option()]) :: {:ok, [binary()]} | {:error, Typsty.RenderError.t()}
      def to_svg(assigns, opts \\ []), do: Typsty.__render__(__MODULE__, :svg, assigns, opts)

      @doc "Renders each page of the document as an SVG, raising `Typsty.RenderError` if it fails."
      @spec to_svg!(Typsty.assigns(), [Typsty.option()]) :: [binary()]
      def to_svg!(assigns, opts \\ []), do: assigns |> to_svg(opts) |> Typsty.__unwrap__!()

      defoverridable to_pdf: 2, to_png: 2, to_svg: 2
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    {template, explicit?} = Module.get_attribute(env.module, :__typsty_template__)
    render_defined? = Module.defines?(env.module, {:render, 1}, :def)
    template_exists? = File.regular?(template)
    relative = Path.relative_to_cwd(template)

    check_render_is_public!(env)

    cond do
      render_defined? and (template_exists? or explicit?) ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description: "#{inspect(env.module)} defines render/1 and has a template (#{relative}). Use one or the other"

      render_defined? ->
        # Recompiles the module if the template is added later, to report both being defined
        quote do
          @external_resource unquote(template)
        end

      template_exists? ->
        source = read_template!(template, env)

        quote do
          @external_resource unquote(template)

          @doc "Returns the template in #{unquote(relative)} with the given assigns."
          @spec render(map()) :: Typsty.Template.t()
          def render(assigns) do
            %Typsty.Template{source: unquote(source), assigns: assigns, file: unquote(template)}
          end
        end

      true ->
        reason = if explicit?, do: "the template #{relative} does not exist", else: "there is no #{relative}"

        raise CompileError,
          file: env.file,
          line: env.line,
          description:
            "#{inspect(env.module)} needs a template: define render/1 using the ~TYPST sigil, " <>
              "or add a template file (#{reason})"
    end
  end

  defp check_render_is_public!(env) do
    if Module.defines?(env.module, {:render, 1}, :defp) do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "#{inspect(env.module)} defines render/1 as private: it must be public (def, not defp)"
    end
  end

  # Reads a .typ template, checking its syntax
  defp read_template!(template, env) do
    source = File.read!(template)

    if not String.valid?(source) do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "the template #{Path.relative_to_cwd(template)} isn't valid UTF-8. Save it as UTF-8"
    end

    validate!(%Template{source: source, file: template})
    source
  end

  @doc """
  The `~TYPST` sigil for writing Typst templates inline.

  Like `~H`, it requires a variable named `assigns` in scope, which the template reads as
  its `assigns` dictionary, and it returns a `Typsty.Template` struct. The template's syntax is checked when
  it's compiled.

  `mix format` formats the template with `Typsty.Formatter`. Use the `noformat` modifier to
  leave a template as it is: `~TYPST\"\"\"...\"\"\"noformat`.
  """
  defmacro sigil_TYPST({:<<>>, meta, [source]}, modifiers)
           when is_binary(source) and modifiers in [[], ~c"noformat"] do
    if not Macro.Env.has_var?(__CALLER__, {:assigns, nil}) do
      raise CompileError,
        file: __CALLER__.file,
        line: __CALLER__.line,
        description: "~TYPST requires a variable named \"assigns\" to exist and be set to a map"
    end

    # A heredoc's content starts on the next line, indented. Other sigils start after `~TYPST"`
    position =
      case Keyword.fetch(meta, :indentation) do
        {:ok, indentation} ->
          [line: __CALLER__.line + 1, column: indentation + 1, indentation: indentation]

        :error ->
          [line: __CALLER__.line, column: Keyword.get(meta, :column, 1) + byte_size(~s(~TYPST")), indentation: 0]
      end

    validate!(struct!(Template, [source: source, file: __CALLER__.file] ++ position))

    quote do
      %Typsty.Template{
        source: unquote(source),
        assigns: var!(assigns),
        file: unquote(__CALLER__.file),
        line: unquote(position[:line]),
        column: unquote(position[:column]),
        indentation: unquote(position[:indentation])
      }
    end
  end

  defmacro sigil_TYPST(_source, modifiers) do
    raise ArgumentError, "~TYPST only supports the noformat modifier, got: #{modifiers}"
  end

  defp validate!(%Template{source: source} = template) do
    case syntax_errors(source) do
      [] -> :ok
      :unavailable -> :ok
      diagnostics -> SyntaxError.raise!(diagnostics, template)
    end
  end

  # When cross-compiling (for Nerves, say), the NIF is built for another machine and can't
  # load where the code compiles: templates are then compiled without checking their syntax
  defp syntax_errors(source) do
    Native.syntax_errors(source)
  rescue
    error in [UndefinedFunctionError, ErlangError] ->
      if match?(%UndefinedFunctionError{module: Native}, error) or
           match?(%ErlangError{original: :nif_not_loaded}, error) do
        # Once per compilation, rather than for every template
        if not :persistent_term.get({__MODULE__, :warned_unavailable}, false) do
          :persistent_term.put({__MODULE__, :warned_unavailable}, true)
          IO.warn("Typsty can't check templates' syntax, since its NIF couldn't be loaded (cross-compiling?)", [])
        end

        :unavailable
      else
        reraise error, __STACKTRACE__
      end
  end

  @doc """
  Renders a template as a PDF.

  The template is a `Typsty.Template` (from the `~TYPST` sigil or a module's `render/1`), or
  a string of Typst source. The template reads the assigns from its `assigns` dictionary; for
  a `Typsty.Template`, they're merged into the assigns it already has.

  ```elixir
  {:ok, pdf} = Typsty.to_pdf("= Hello #assigns.name", %{name: "World"})
  ```

  See [Options](#module-options) for the options.
  """
  @spec to_pdf(template(), assigns(), [option()]) :: {:ok, binary()} | {:error, RenderError.t()}
  def to_pdf(template, assigns \\ %{}, opts \\ []), do: template |> template(assigns) |> render(:pdf, opts, nil)

  @doc "Like `to_pdf/3`, but raises `Typsty.RenderError` if rendering fails."
  @spec to_pdf!(template(), assigns(), [option()]) :: binary()
  def to_pdf!(template, assigns \\ %{}, opts \\ []), do: template |> to_pdf(assigns, opts) |> __unwrap__!()

  @doc """
  Renders each page of a template as a PNG. Takes the same arguments as `to_pdf/3`, and the
  `:ppi` option sets the resolution.
  """
  @spec to_png(template(), assigns(), [option()]) :: {:ok, [binary()]} | {:error, RenderError.t()}
  def to_png(template, assigns \\ %{}, opts \\ []), do: template |> template(assigns) |> render(:png, opts, nil)

  @doc "Like `to_png/3`, but raises `Typsty.RenderError` if rendering fails."
  @spec to_png!(template(), assigns(), [option()]) :: [binary()]
  def to_png!(template, assigns \\ %{}, opts \\ []), do: template |> to_png(assigns, opts) |> __unwrap__!()

  @doc "Renders each page of a template as an SVG. Takes the same arguments as `to_pdf/3`."
  @spec to_svg(template(), assigns(), [option()]) :: {:ok, [binary()]} | {:error, RenderError.t()}
  def to_svg(template, assigns \\ %{}, opts \\ []), do: template |> template(assigns) |> render(:svg, opts, nil)

  @doc "Like `to_svg/3`, but raises `Typsty.RenderError` if rendering fails."
  @spec to_svg!(template(), assigns(), [option()]) :: [binary()]
  def to_svg!(template, assigns \\ %{}, opts \\ []), do: template |> to_svg(assigns, opts) |> __unwrap__!()

  @doc """
  Checks the syntax of Typst source. Returns `{:error, diagnostics}` with the syntax errors
  if it's invalid.

  The `~TYPST` sigil and `.typ` templates are checked when they're compiled; this is for
  templates that come from elsewhere, such as a database.
  """
  @spec validate(String.t()) :: :ok | {:error, [Diagnostic.t()]}
  def validate(source) when is_binary(source) do
    case Native.syntax_errors(utf8!(source, "the Typst source")) do
      [] -> :ok
      diagnostics -> {:error, diagnostics}
    end
  end

  def validate(other), do: raise(ArgumentError, "expected Typst source (a string), got: #{inspect(other)}")

  @doc """
  Formats Typst source with [typstyle](https://github.com/typstyle-rs/typstyle). Returns
  `{:error, diagnostics}` if the source has syntax errors, since it can't be formatted then.

  ## Options

  #{Options.docs(:format)}
  """
  @spec format(String.t(), [format_option()]) :: {:ok, String.t()} | {:error, [Diagnostic.t()]}
  def format(source, opts \\ [])

  def format(source, opts) when is_binary(source) do
    opts = Options.format!(opts)

    Native.format(utf8!(source, "the Typst source"), %{
      line_width: opts[:line_length],
      indent_width: opts[:indent],
      wrap_text: opts[:wrap_text]
    })
  end

  def format(other, _opts), do: raise(ArgumentError, "expected Typst source (a string), got: #{inspect(other)}")

  @doc """
  Returns the names of the font families available to documents with the given font options
  (`:font_paths`, `:system_fonts` and `:embedded_fonts`, with the same defaults as for
  rendering).

  The fonts are scanned once for each combination of options and cached, so calling this
  when your application starts makes the first render faster.
  """
  @spec font_families([font_option()]) :: [String.t()]
  def font_families(opts \\ []) do
    opts |> Options.fonts!() |> font_options() |> Native.font_families()
  end

  @doc """
  Returns the number of renders running inside the VM, including renders that timed out
  and are still being cancelled. Useful in health checks and metrics: it's at most
  `:max_concurrent_renders`. Renders in a `Typsty.Pool` aren't counted.
  """
  @spec running_renders() :: non_neg_integer()
  def running_renders, do: Native.running_renders()

  @doc """
  Returns the version of the Typst compiler that Typsty uses, such as `"0.15.1"`.
  """
  @spec typst_version() :: String.t()
  def typst_version, do: Native.typst_version()

  @doc false
  @spec __render__(module(), :pdf | :png | :svg, assigns(), [option()]) ::
          {:ok, binary() | [binary()]} | {:error, RenderError.t()}
  def __render__(module, format, assigns, opts) do
    case module.render(assigns!(assigns)) do
      %Template{} = template ->
        render(template, format, opts, module)

      other ->
        raise ArgumentError, "#{inspect(module)}.render/1 must return a ~TYPST template, got: #{inspect(other)}"
    end
  end

  @doc false
  @spec __unwrap__!({:ok, result} | {:error, RenderError.t()}) :: result when result: term()
  def __unwrap__!({:ok, result}), do: result
  def __unwrap__!({:error, %RenderError{} = error}), do: raise(error)

  defp template(source, assigns) when is_binary(source) do
    %Template{source: utf8!(source, "the Typst source"), assigns: assigns!(assigns)}
  end

  defp template(%Template{source: source} = template, assigns) when is_binary(source) do
    utf8!(source, "the template's source")
    %{template | assigns: Map.merge(assigns!(template.assigns), assigns!(assigns))}
  end

  defp template(%Template{source: source}, _assigns) do
    raise ArgumentError, "the template's source must be a string, got: #{inspect(source)}"
  end

  defp template(module, _assigns) when is_atom(module) and module not in [nil, true, false] do
    raise ArgumentError,
          "expected Typst source or a Typsty.Template, got: #{inspect(module)}. " <>
            "To render a document module, call its functions, like #{inspect(module)}.to_pdf(assigns)"
  end

  defp template(other, _assigns) do
    raise ArgumentError, "expected Typst source (a string) or a Typsty.Template, got: #{inspect(other)}"
  end

  defp utf8!(source, what) do
    if String.valid?(source) do
      source
    else
      raise ArgumentError, "#{what} isn't valid UTF-8"
    end
  end

  defp assigns!(%_{} = struct) do
    raise ArgumentError,
          "the assigns must be a map, got a #{inspect(struct.__struct__)} struct. " <>
            "Put it in a map, like %{invoice: invoice}, to pass it to the template"
  end

  defp assigns!(assigns) when is_map(assigns), do: assigns

  defp assigns!(assigns) when is_list(assigns) do
    raise ArgumentError,
          "the assigns must be a map, got a list: #{inspect(assigns)}. Options go after the assigns: " <>
            "MyApp.Invoice.to_png(%{}, ppi: 300) for a document module, Typsty.to_png(source, %{}, ppi: 300) otherwise"
  end

  defp assigns!(assigns), do: raise(ArgumentError, "the assigns must be a map, got: #{inspect(assigns)}")

  defp render(%Template{} = template, format, opts, module) do
    metadata = %{module: module, format: format, template: template}

    :telemetry.span([:typsty, :render], metadata, fn ->
      opts = Options.render!(opts)
      assigns = Value.assigns(template.assigns)
      pool = pool!(opts[:pool])
      native_opts = __native_options__(opts, format)

      case render_with(pool, template.source, assigns, Keyword.get(opts, :files, []), native_opts) do
        {:ok, output, warnings} ->
          warnings = Enum.map(warnings, &Diagnostic.locate(&1, template))
          log_warnings(warnings, opts[:log_warnings])
          {{:ok, output}, Map.merge(metadata, %{result: :ok, diagnostics: warnings})}

        {:error, :invalid, message} ->
          raise ArgumentError, message

        {:error, reason, details} ->
          diagnostics = diagnostics(reason, details, template, native_opts)
          error = %RenderError{reason: reason, diagnostics: diagnostics}
          {{:error, error}, Map.merge(metadata, %{result: :error, reason: reason, diagnostics: diagnostics})}
      end
    end)
  end

  # Sending a checkout to another kind of process would crash it
  defp pool_process!(pid, pool) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        if not Typsty.Pool.__pool__?(dictionary) do
          raise ArgumentError, "the :pool option must be a Typsty.Pool, got: #{inspect(pool)}"
        end

        pid

      nil ->
        {:not_running, pool}
    end
  end

  @doc false
  # The options as the NIF and the pool's workers take them, from validated options
  @spec __native_options__(keyword(), :pdf | :png | :svg) :: map()
  def __native_options__(opts, format) do
    %{
      format: format,
      root: opts[:root] && Path.expand(opts[:root]),
      package_paths: Enum.map(opts[:package_paths], &Path.expand/1),
      fonts: font_options(opts),
      ppi: opts[:ppi] * 1.0,
      pdf_standards: Enum.uniq(opts[:pdf_standards]),
      timeout: if(opts[:timeout] == :infinity, do: nil, else: opts[:timeout]),
      max_running: opts[:max_concurrent_renders]
    }
  end

  defp diagnostics(:typst, diagnostics, template, native_opts) do
    Enum.map(diagnostics, &(&1 |> Diagnostic.locate(template) |> rewrite_hints(native_opts)))
  end

  defp diagnostics(_reason, message, _template, _native_opts) when is_binary(message) do
    [%Diagnostic{severity: :error, message: message}]
  end

  # A package that isn't in the :package_paths directories. The whole message must match, since
  # messages can quote a template's data
  @missing_package ~r/\Apackage not found \(searched for (@([\p{L}_][\p{L}\p{N}_-]*)\/([\p{L}_][\p{L}\p{N}_-]*):(\d+\.\d+\.\d+))\)\z/u

  # Typst's hints are written for its command-line tool, which takes a --root argument
  @root_hint ~r/--root/

  defp rewrite_hints(%Diagnostic{message: message, hints: hints} = diagnostic, native_opts) do
    hints =
      Enum.map(hints, fn hint ->
        if hint =~ @root_hint,
          do: "files outside the project root can only be read by changing the :root option",
          else: hint
      end)

    case Regex.run(@missing_package, message) do
      [_ | spec] -> %{diagnostic | hints: hints ++ [package_hint(spec, native_opts.package_paths)]}
      nil -> %{diagnostic | hints: hints}
    end
  end

  defp package_hint([spec, namespace, name, version], package_paths) do
    # A directory that has the package one level down names the namespace's directory,
    # rather than the one that holds it
    case Enum.find(package_paths, &File.dir?(Path.join([&1, name, version]))) do
      nil when namespace == "preview" ->
        "download it with `mix typsty.packages.get #{spec}`, and add the directory it's saved in " <>
          "to the :package_paths option. #{searched(package_paths)}"

      nil ->
        "add the directory that holds #{namespace}/#{name}/#{version} to the :package_paths option. " <>
          searched(package_paths)

      path ->
        "#{path} has the package, but :package_paths must name the directory that holds " <>
          "#{namespace}/: #{Path.dirname(path)}"
    end
  end

  defp searched([]), do: "The :package_paths option is empty, so no directories were searched"
  defp searched(paths), do: "Searched " <> Enum.map_join(paths, ", ", &describe_path/1)

  defp describe_path(path), do: if(File.dir?(path), do: path, else: "#{path} (which doesn't exist)")

  defp render_with(nil, source, assigns, files, native_opts) do
    reference = make_ref()

    case Native.start_render(reference, source, assigns, files, native_opts) do
      {:ok, job} -> await(reference, job, native_opts.timeout, native_opts.max_running)
      {:error, _reason, _message} = error -> error
    end
  end

  defp render_with({:not_running, pool}, _source, _assigns, _files, _native_opts) do
    {:error, :crashed,
     "the pool #{inspect(pool)} isn't running (a Typsty.Pool in a supervision tree may be restarting)"}
  end

  defp render_with(pool, source, assigns, files, native_opts) do
    Typsty.Pool.__render__(pool, source, assigns, files, native_opts)
  end

  # The render's thread sends its result. Holding on to the job until then keeps the render
  # going: once the job is garbage collected (when this process exits, say), it's cancelled.
  defp await(reference, job, timeout, max_running) do
    receive do
      {^reference, result} -> result
    after
      timeout || :infinity ->
        case Native.cancel_render(job) do
          :queued ->
            {:error, :busy,
             "rendering didn't start within the timeout (#{timeout} ms): " <>
               "#{max_running} #{if max_running == 1, do: "render was", else: "renders were"} already running " <>
               "(the :max_concurrent_renders limit), counting renders that timed out and are still being cancelled"}

          :running ->
            {:error, :timeout, "rendering didn't finish within the timeout (#{timeout} ms), and is being cancelled"}

          :finished ->
            receive do
              {^reference, result} -> result
            end

          # The render ended, but its result couldn't be sent (a bug)
          :abandoned ->
            {:error, :crashed, "the render ended, but its result couldn't be sent"}
        end
    end
  end

  defp font_options(opts) do
    %{
      font_paths: Enum.map(opts[:font_paths], &Path.expand/1),
      system_fonts: opts[:system_fonts],
      embedded_fonts: opts[:embedded_fonts]
    }
  end

  defp log_warnings(warnings, true), do: Enum.each(warnings, &log_warning/1)
  defp log_warnings(_warnings, false), do: :ok

  # Messages can quote a template's data, whose line breaks would start what looks like
  # another log entry
  defp log_warning(warning) do
    Logger.warning(fn ->
      warning = %{warning | message: one_line(warning.message), hints: Enum.map(warning.hints, &one_line/1)}
      "[Typsty] " <> Diagnostic.format(warning)
    end)
  end

  defp one_line(text), do: text |> String.replace("\r", "\\r") |> String.replace("\n", "\\n")

  # The pool's pid. Options.render!/1 checked that it's a name or a pid. A pool that isn't
  # running (one that's restarting, say) is an error like a pool that stops during a render
  defp pool!(nil), do: nil

  defp pool!(pool) do
    case GenServer.whereis(pool) do
      pid when is_pid(pid) and node(pid) == node() ->
        pool_process!(pid, pool)

      nil ->
        {:not_running, pool}

      _remote ->
        raise ArgumentError,
              "the :pool option must be a Typsty.Pool on this node (its workers are local processes), got: #{inspect(pool)}"
    end
  end
end
