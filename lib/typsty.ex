defmodule Typsty do
  @moduledoc """
  Render [Typst](https://typst.app) documents to PDF, PNG and SVG, with Elixir data passed
  to the template as regular Typst variables.

  ## Document modules

  A document module does `use Typsty` and either defines `render/1` with the `~TYPST` sigil:

  ```elixir
  defmodule MyApp.Invoice do
    use Typsty

    def render(assigns) do
      ~TYPST\"\"\"
      #set page(paper: "us-letter")

      = Invoice #number

      #table(
        columns: (1fr, auto),
        [*Item*], [*Price*],
        ..items.map(item => (item.name, [\\$#item.price])).flatten(),
      )
      \"\"\"
    end
  end
  ```

  or leaves `render/1` out and puts the template in a `.typ` file next to the module, with
  the same base name (`invoice.ex` and `invoice.typ`), like LiveView's colocated templates.

  Render it with the generated functions:

  ```elixir
  {:ok, pdf} = MyApp.Invoice.to_pdf(%{number: 1042, items: [%{name: "Widget", price: 25}]})
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

  ## Variables

  The assigns become regular Typst variables in the template: `number` and `items` above.
  Typst gets the data itself, not code generated from it, so nothing needs escaping, and the
  template can loop over lists, read fields and do arithmetic:

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
  | other structs                             | see `Typsty.Encoder`                   |

  Top-level keys must be valid Typst identifiers (`invoice_number` or `invoice-number`, but
  not `invoice number` or `for`). Map keys inside the data can be anything.

  Like `let` bindings in the template, the variables are only visible in the template
  itself, so they never shadow Typst's standard library in imported files or packages. A
  variable named after a standard library function (such as `title`) shadows it in the
  template only; the function is still available as `std.title`. Other files can read the
  variables from `sys.inputs`, which is also how a template can make a variable optional:

  ```typst
  #let subtitle = sys.inputs.at("subtitle", default: none)
  ```

  `render/1` gets the assigns before the template does, so it can compute values for it:

  ```elixir
  def render(assigns) do
    assigns = Map.put(assigns, :total, Enum.sum_by(assigns.items, & &1.price))

    ~TYPST\"\"\"
    Total: #total
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

  Paths are relative to the project root (`"logo.png"` and `"/logo.png"` are the same file).
  To also read files from a directory, set `:root`; files given with `:files` take
  precedence. Without `:root`, the document can only read the files it's given.

  Typst interns every file path it sees for the life of the VM, up to 65,536 of them. Use
  stable names, like `logo.png` or `photos/1.jpg`, rather than a unique name per render.

  ## Options

  Rendering takes these options. All of them, except `:files`, can also be set in your
  application config, as defaults for every render:

  ```elixir
  config :typsty, font_paths: ["priv/fonts"], system_fonts: false
  ```

  - `:files` - a map (or list of tuples) of paths to binaries, as above.
  - `:root` - a directory to read the files that aren't in `:files` from. Defaults to `nil`.
  - `:font_paths` - directories to load fonts from, searched recursively. Defaults to `[]`.
  - `:system_fonts` - whether to use the fonts installed on the system. Defaults to `true`.
    Turn it off for documents that render the same on every machine.
  - `:embedded_fonts` - whether to use the fonts that come with Typst (Libertinus Serif,
    New Computer Modern, New Computer Modern Math and DejaVu Sans Mono). Defaults to `true`.
  - `:package_paths` - directories with Typst packages, laid out as
    `namespace/name/version`, like Typst's package cache. A template can import a package
    from them with `#import "@preview/cetz:0.4.2"`. Packages are never downloaded while
    rendering: fetch them ahead of time with `mix typsty.packages.get`. Defaults to `[]`.
  - `:ppi` - for PNG, the resolution in pixels per inch. Defaults to `144`.
  - `:pdf_standards` - for PDF, the standards to conform to, such as `["a-2b"]` or
    `["ua-1"]`. Defaults to `[]`.
  - `:timeout` - how long to wait for the render, in milliseconds, or `:infinity`, including
    the time spent waiting for a free slot (see `:max_concurrent_renders` below). Defaults
    to `60_000`. A render that times out returns an error and is cancelled: it stops the
    next time Typst lays out content, loads a file or a font, or exports a page, which
    for most documents is within milliseconds. A template doing pure computation (a long
    loop of arithmetic) keeps running until it gets to one of those.

  Renders also share one setting that can only be set in the application config:

  - `:max_concurrent_renders` - how many renders may run at once, counting renders that
    timed out and are still being cancelled. A render waits for a free slot, within its
    timeout. This keeps renders that keep timing out from piling up in the background.
    Defaults to the number of dirty CPU schedulers (the number of CPU cores), which is
    how many renders can run at once anyway. See `running_renders/0`.

  Fonts are scanned once for each combination of `:font_paths`, `:system_fonts` and
  `:embedded_fonts` and then cached, so only the first render with given font settings
  pays for scanning them. Call `font_families/1` when your application starts to scan them
  ahead of time.

  ## Warnings

  Typst's warnings (an unknown font family, for example) are logged with `Logger.warning/1`
  and included in the `:stop` telemetry event (see `Typsty.Telemetry`). To stop logging them:

  ```elixir
  config :typsty, log_warnings: false
  ```
  """

  require Logger

  alias Typsty.{Diagnostic, Native, RenderError, SyntaxError, Template, Value}

  @template_extension ".typ"

  @configurable_options [
    :root,
    :package_paths,
    :font_paths,
    :system_fonts,
    :embedded_fonts,
    :ppi,
    :pdf_standards,
    :timeout
  ]

  @default_options [
    files: [],
    root: nil,
    package_paths: [],
    font_paths: [],
    system_fonts: true,
    embedded_fonts: true,
    ppi: 144,
    pdf_standards: [],
    timeout: 60_000
  ]

  @typedoc "Assigns for a template: a map or keyword list with atom or string keys."
  @type assigns :: map() | keyword()

  @typedoc "A template: Typst source, or a template from the `~TYPST` sigil or `render/1`."
  @type template :: String.t() | Template.t()

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
    module's file name with the `.typ` extension. Only used when the module doesn't define
    `render/1`.
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
      @spec to_pdf(Typsty.assigns(), keyword()) :: {:ok, binary()} | {:error, Typsty.RenderError.t()}
      def to_pdf(assigns, opts \\ []), do: Typsty.__render__(__MODULE__, :pdf, assigns, opts)

      @doc "Renders the document as a PDF, raising `Typsty.RenderError` if it fails."
      @spec to_pdf!(Typsty.assigns(), keyword()) :: binary()
      def to_pdf!(assigns, opts \\ []), do: assigns |> to_pdf(opts) |> Typsty.__unwrap__!()

      @doc "Renders each page of the document as a PNG. See `Typsty.to_png/3` for the options."
      @spec to_png(Typsty.assigns(), keyword()) :: {:ok, [binary()]} | {:error, Typsty.RenderError.t()}
      def to_png(assigns, opts \\ []), do: Typsty.__render__(__MODULE__, :png, assigns, opts)

      @doc "Renders each page of the document as a PNG, raising `Typsty.RenderError` if it fails."
      @spec to_png!(Typsty.assigns(), keyword()) :: [binary()]
      def to_png!(assigns, opts \\ []), do: assigns |> to_png(opts) |> Typsty.__unwrap__!()

      @doc "Renders each page of the document as an SVG. See `Typsty.to_svg/3` for the options."
      @spec to_svg(Typsty.assigns(), keyword()) :: {:ok, [binary()]} | {:error, Typsty.RenderError.t()}
      def to_svg(assigns, opts \\ []), do: Typsty.__render__(__MODULE__, :svg, assigns, opts)

      @doc "Renders each page of the document as an SVG, raising `Typsty.RenderError` if it fails."
      @spec to_svg!(Typsty.assigns(), keyword()) :: [binary()]
      def to_svg!(assigns, opts \\ []), do: assigns |> to_svg(opts) |> Typsty.__unwrap__!()

      defoverridable to_pdf: 2, to_png: 2, to_svg: 2
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    {template, explicit?} = Module.get_attribute(env.module, :__typsty_template__)
    render_defined? = Module.defines?(env.module, {:render, 1})
    template_exists? = File.regular?(template)
    relative = Path.relative_to_cwd(template)

    cond do
      render_defined? and template_exists? ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description: "#{inspect(env.module)} defines render/1 and has a template at #{relative}. Use one or the other"

      render_defined? ->
        # Recompiles the module if the template is added later, to report both being defined
        quote do
          @external_resource unquote(template)
        end

      template_exists? ->
        source = File.read!(template)
        validate!(%Template{source: source, file: template})

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

  @doc """
  The `~TYPST` sigil for writing Typst templates inline.

  Like `~H`, it requires a variable named `assigns` in scope, which becomes the template's
  variables, and it returns a `Typsty.Template` struct. The template's syntax is checked when
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
    case Native.syntax_errors(source) do
      [] -> :ok
      diagnostics -> SyntaxError.raise!(diagnostics, template)
    end
  end

  @doc """
  Renders a template as a PDF.

  The template is a `Typsty.Template` (from the `~TYPST` sigil or a module's `render/1`), or
  a string of Typst source. The assigns become the template's variables; for a
  `Typsty.Template`, they're merged into the assigns it already has.

  ```elixir
  {:ok, pdf} = Typsty.to_pdf("= Hello #name", %{name: "World"})
  ```

  See [Options](#module-options) for the options.
  """
  @spec to_pdf(template(), assigns(), keyword()) :: {:ok, binary()} | {:error, RenderError.t()}
  def to_pdf(template, assigns \\ %{}, opts \\ []), do: template |> template(assigns) |> render(:pdf, opts, nil)

  @doc "Like `to_pdf/3`, but raises `Typsty.RenderError` if rendering fails."
  @spec to_pdf!(template(), assigns(), keyword()) :: binary()
  def to_pdf!(template, assigns \\ %{}, opts \\ []), do: template |> to_pdf(assigns, opts) |> __unwrap__!()

  @doc """
  Renders each page of a template as a PNG. Takes the same arguments as `to_pdf/3`, and the
  `:ppi` option sets the resolution.
  """
  @spec to_png(template(), assigns(), keyword()) :: {:ok, [binary()]} | {:error, RenderError.t()}
  def to_png(template, assigns \\ %{}, opts \\ []), do: template |> template(assigns) |> render(:png, opts, nil)

  @doc "Like `to_png/3`, but raises `Typsty.RenderError` if rendering fails."
  @spec to_png!(template(), assigns(), keyword()) :: [binary()]
  def to_png!(template, assigns \\ %{}, opts \\ []), do: template |> to_png(assigns, opts) |> __unwrap__!()

  @doc "Renders each page of a template as an SVG. Takes the same arguments as `to_pdf/3`."
  @spec to_svg(template(), assigns(), keyword()) :: {:ok, [binary()]} | {:error, RenderError.t()}
  def to_svg(template, assigns \\ %{}, opts \\ []), do: template |> template(assigns) |> render(:svg, opts, nil)

  @doc "Like `to_svg/3`, but raises `Typsty.RenderError` if rendering fails."
  @spec to_svg!(template(), assigns(), keyword()) :: [binary()]
  def to_svg!(template, assigns \\ %{}, opts \\ []), do: template |> to_svg(assigns, opts) |> __unwrap__!()

  @doc """
  Checks the syntax of Typst source. Returns `{:error, diagnostics}` with the syntax errors
  if it's invalid.

  The `~TYPST` sigil and `.typ` templates are checked when they're compiled; this is for
  templates that come from elsewhere, such as a database.
  """
  @spec validate(String.t()) :: :ok | {:error, [Diagnostic.t()]}
  def validate(source) when is_binary(source) do
    case Native.syntax_errors(source) do
      [] -> :ok
      diagnostics -> {:error, diagnostics}
    end
  end

  @doc """
  Formats Typst source with [typstyle](https://github.com/typstyle-rs/typstyle). Returns
  `{:error, diagnostics}` if the source has syntax errors, since it can't be formatted then.

  ## Options

  - `:line_length` - the maximum line length. Defaults to `80`.
  - `:indent` - the number of spaces to indent by. Defaults to `2`.
  - `:wrap_text` - whether to wrap long lines of text in markup. Defaults to `false`.
  """
  @spec format(String.t(), keyword()) :: {:ok, String.t()} | {:error, [Diagnostic.t()]}
  def format(source, opts \\ []) when is_binary(source) do
    opts = Keyword.validate!(opts, line_length: 80, indent: 2, wrap_text: false)

    Native.format(source, %{
      line_width: positive_integer!(opts[:line_length], :line_length),
      indent_width: positive_integer!(opts[:indent], :indent),
      wrap_text: boolean!(opts[:wrap_text], :wrap_text)
    })
  end

  @doc """
  Returns the names of the font families available to documents with the given font options
  (`:font_paths`, `:system_fonts` and `:embedded_fonts`, with the same defaults as for
  rendering).

  The fonts are scanned once for each combination of options and cached, so calling this
  when your application starts makes the first render faster.
  """
  @spec font_families(keyword()) :: [String.t()]
  def font_families(opts \\ []) do
    opts = opts |> Keyword.validate!([:font_paths, :system_fonts, :embedded_fonts]) |> with_defaults()
    Native.font_families(font_options(opts))
  end

  @doc """
  Returns the number of renders running, including renders that timed out and are still
  being cancelled. Useful in health checks and metrics: it's at most
  `:max_concurrent_renders`.
  """
  @spec running_renders() :: non_neg_integer()
  def running_renders, do: Native.running_renders()

  @doc """
  Returns the version of the Typst compiler that Typsty uses, such as `"0.15.1"`.
  """
  @spec typst_version() :: String.t()
  def typst_version, do: Native.typst_version()

  @doc false
  @spec __render__(module(), :pdf | :png | :svg, assigns(), keyword()) ::
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

  defp template(source, assigns) when is_binary(source), do: %Template{source: source, assigns: assigns!(assigns)}

  defp template(%Template{} = template, assigns) do
    %{template | assigns: Map.merge(assigns!(template.assigns), assigns!(assigns))}
  end

  defp assigns!(assigns) when is_map(assigns), do: assigns

  defp assigns!(assigns) when is_list(assigns) do
    if Keyword.keyword?(assigns) do
      Map.new(assigns)
    else
      raise ArgumentError, "the assigns must be a map or a keyword list, got: #{inspect(assigns)}"
    end
  end

  defp assigns!(assigns),
    do: raise(ArgumentError, "the assigns must be a map or a keyword list, got: #{inspect(assigns)}")

  defp render(%Template{} = template, format, opts, module) do
    metadata = %{module: module, format: format, template: template}

    :telemetry.span([:typsty, :render], metadata, fn ->
      opts = opts |> Keyword.validate!(Keyword.keys(@default_options)) |> with_defaults()
      variables = Value.variables(template.assigns)
      files = files!(opts[:files])

      native_opts = %{
        format: format,
        root: opts[:root] && Path.expand(opts[:root]),
        package_paths: paths!(opts[:package_paths], :package_paths),
        fonts: font_options(opts),
        ppi: opts[:ppi] |> positive_number!(:ppi) |> Kernel.*(1.0),
        pdf_standards: strings!(opts[:pdf_standards], :pdf_standards),
        timeout: timeout!(opts[:timeout]),
        max_running: max_concurrent_renders!()
      }

      case Native.render(template.source, variables, files, native_opts) do
        {:ok, output, warnings} ->
          warnings = Enum.map(warnings, &Diagnostic.locate(&1, template))
          log_warnings(warnings)
          {{:ok, output}, Map.merge(metadata, %{result: :ok, diagnostics: warnings})}

        {:error, message} when is_binary(message) ->
          raise ArgumentError, message

        {:error, diagnostics} ->
          diagnostics = Enum.map(diagnostics, &(&1 |> Diagnostic.locate(template) |> package_hint()))

          {{:error, %RenderError{diagnostics: diagnostics}},
           Map.merge(metadata, %{result: :error, diagnostics: diagnostics})}
      end
    end)
  end

  # A package from Typst Universe that isn't in the :package_paths directories
  @missing_package ~r/package not found \(searched for (@preview\/[^\s)]+)\)/

  defp package_hint(%Diagnostic{message: message, hints: hints} = diagnostic) do
    case Regex.run(@missing_package, message) do
      [_, spec] ->
        hint =
          "download it with `mix typsty.packages.get #{spec}`, " <>
            "and add the directory it's saved in to the :package_paths option"

        %{diagnostic | hints: hints ++ [hint]}

      nil ->
        diagnostic
    end
  end

  defp with_defaults(opts) do
    config = :typsty |> Application.get_all_env() |> Keyword.take(@configurable_options)

    @default_options
    |> Keyword.merge(config)
    |> Keyword.merge(opts)
  end

  defp font_options(opts) do
    %{
      font_paths: paths!(opts[:font_paths], :font_paths),
      system_fonts: boolean!(opts[:system_fonts], :system_fonts),
      embedded_fonts: boolean!(opts[:embedded_fonts], :embedded_fonts)
    }
  end

  defp log_warnings(warnings) do
    if Application.get_env(:typsty, :log_warnings, true) do
      Enum.each(warnings, &log_warning/1)
    end
  end

  defp log_warning(warning), do: Logger.warning(fn -> "[Typsty] " <> Diagnostic.format(warning) end)

  defp files!(files) when is_map(files) or is_list(files) do
    Enum.map(files, fn
      {path, contents} when is_binary(path) and is_binary(contents) ->
        {path, contents}

      other ->
        raise ArgumentError, "the :files option must map paths to binaries, got: #{inspect(other, limit: 5)}"
    end)
  end

  defp files!(files), do: raise(ArgumentError, "the :files option must be a map or a list, got: #{inspect(files)}")

  defp paths!(paths, option) do
    paths
    |> strings!(option)
    |> Enum.map(&Path.expand/1)
  end

  defp strings!(strings, option) do
    if is_list(strings) and Enum.all?(strings, &is_binary/1) do
      strings
    else
      raise ArgumentError, "the #{inspect(option)} option must be a list of strings, got: #{inspect(strings)}"
    end
  end

  defp boolean!(value, _option) when is_boolean(value), do: value

  defp boolean!(value, option),
    do: raise(ArgumentError, "the #{inspect(option)} option must be a boolean, got: #{inspect(value)}")

  defp positive_number!(value, _option) when is_number(value) and value > 0, do: value

  defp positive_number!(value, option) do
    raise ArgumentError, "the #{inspect(option)} option must be a positive number, got: #{inspect(value)}"
  end

  defp max_concurrent_renders! do
    case Application.get_env(:typsty, :max_concurrent_renders, :erlang.system_info(:dirty_cpu_schedulers)) do
      limit when is_integer(limit) and limit > 0 ->
        limit

      other ->
        raise ArgumentError, "the :max_concurrent_renders config must be a positive integer, got: #{inspect(other)}"
    end
  end

  defp timeout!(:infinity), do: nil
  defp timeout!(timeout) when is_integer(timeout) and timeout > 0, do: timeout

  defp timeout!(timeout) do
    raise ArgumentError, "the :timeout option must be a positive integer or :infinity, got: #{inspect(timeout)}"
  end

  defp positive_integer!(value, _option) when is_integer(value) and value > 0, do: value

  defp positive_integer!(value, option) do
    raise ArgumentError, "the #{inspect(option)} option must be a positive integer, got: #{inspect(value)}"
  end
end
