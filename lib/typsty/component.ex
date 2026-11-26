defmodule Typsty.Component do
  @moduledoc """
  Reusable parts of documents, such as tables, letterheads, headers and footers, written as
  Typst functions that documents import.

  A component is a module that does `use Typsty.Component`. Its Typst source is in a `.typ`
  file next to it, with the same base name (`tables.ex` and `tables.typ`), or in a
  `render/0` that returns a `~TYPST` sigil:

  ```elixir
  defmodule MyApp.Documents.Tables do
    use Typsty.Component

    def render do
      ~TYPST\"\"\"
      #let line-items(items, currency: "$") = table(
        columns: (1fr, auto),
        [*Item*], [*Price*],
        ..items.map(item => (item.name, [#currency#item.price])).flatten(),
      )
      \"\"\"
    end
  end
  ```

  A document lists the components it uses, and imports each one from
  `components/<name>.typ`, where the name is the last part of the module's name, in snake
  case (`tables` here, and `line_items` for `MyApp.Documents.LineItems`):

  ```elixir
  defmodule MyApp.Invoice do
    use Typsty, components: [MyApp.Documents.Tables]

    def render(assigns) do
      ~TYPST\"\"\"
      #import "components/tables.typ": line-items

      = Invoice #assigns.number
      #line-items(assigns.items)
      \"\"\"
    end
  end
  ```

  Templates rendered from strings get components with the `:components` option:
  `Typsty.to_pdf(source, assigns, components: [MyApp.Documents.Tables])`. They work the same
  in a `Typsty.Pool`.

  ## Headers and footers

  A component that lays out pages, with a header and a footer, is a template function: a
  function that takes the document's content as its last argument and sets up the pages
  around it. Documents apply it to everything that follows with a show rule:

  ```typst
  // letterhead.typ, next to letterhead.ex
  #let letterhead(title: none, logo: none, body) = {
    set page(
      header: [#logo #h(1fr) #title],
      footer: context [Page #counter(page).display() of #counter(page).final().first()],
    )
    body
  }
  ```

  ```typst
  #import "components/letterhead.typ": letterhead
  #show: letterhead.with(title: [Invoice #assigns.number], logo: image("logo.png", height: 1cm))
  ```

  ## What components can have

  A component only defines things. When its module compiles, Typsty checks that its top
  level only has definitions (`#let`), imports (`#import`), comments and blank lines, and
  raises `Typsty.SyntaxError` otherwise:

  - Content outside a function, such as text or a `#table(...)`, would never appear in the
    documents that import the component, and `#include` would make it a partial.
  - A set or show rule outside a function only applies to the component's own file. Put it
    in a function, like the letterhead's `set page(...)`.

  Definitions don't have to be functions: `#let brand-blue = rgb("#1a4d8f")` is one too.

  A component only gets data as arguments, which keeps it independent of the documents that
  use it. Like any file a template imports, it doesn't see the template's `assigns`, and it
  can't read `sys.inputs` either, where Typst passes them: that's refused when it compiles
  too. The check reads the source as written, so it catches `sys.inputs` and imports of
  `inputs` from `sys`, not `sys` passed around under another name.

  Files that change from document to document, such as a customer's logo, are passed as
  arguments too, from the document's `:files`, like the letterhead's `logo` above. Files
  that belong to the component are in its folder (see [Files](#module-files)).

  ## Files

  A component's own files, such as its images and data, go in a folder next to its module,
  with the same base name (`letterhead/`, next to `letterhead.ex`), or the folder given with
  the `:files` option:

  ```
  lib/my_app/documents/letterhead.ex
  lib/my_app/documents/letterhead.typ
  lib/my_app/documents/letterhead/
      seal.svg
      offices.json
  ```

  Renders get them at `components/<name>/`, next to the component's own
  `components/<name>.typ`, so the component reads them by that path:

  ```typst
  // letterhead.typ
  #let offices = json("letterhead/offices.json")
  #let letterhead(title: none, body) = {
    set page(header: [#image("letterhead/seal.svg", height: 1cm) #h(1fr) #title])
    body
  }
  ```

  Documents can read them too: `#image("components/letterhead/seal.svg")`.

  - The files are read when the module compiles, and kept in it, so they work in releases
    (which don't have `lib/`), and in a `Typsty.Pool`. Changing a file recompiles the
    component, as does adding one or taking one out.
  - Hidden files and folders, such as `.DS_Store`, are left out.
  - `.typ` files in the folder are checked like components, and their errors point at
    them. Paths in them are relative to them, as Typst reads them.
  - The paths that a component reads its files from, when they're written out (as in
    `image("letterhead/seal.svg")`), are checked when it compiles, so a file that isn't
    there fails the build. Paths built when it renders (`image("letterhead/" + name)`)
    can't be checked then.
  - Every render that lists the component gets its files, which takes about a third of a
    millisecond per MiB in a `Typsty.Pool`. Compiling a component whose files take more
    than 8 MiB warns: files that only some documents use are better passed with their
    `:files`.
  - Fonts aren't read from a component's folder: Typst finds fonts by family name, from the
    `:font_paths` directories, and the system's and Typst's own fonts.

  A folder next to a module with its base name can also hold modules nested in it
  (`letterhead/margins.ex`), which aren't the component's files: a folder with `.ex` or
  `.exs` files in it is refused, unless the component is given another folder, or
  `files: false` for none.

  ## Components that use other components

  A component lists the components it imports, and documents that list it get them too:

  ```elixir
  defmodule MyApp.Documents.Letterhead do
    use Typsty.Component, components: [MyApp.Documents.Brand]
  end
  ```

  Components are next to each other in `components/`, so one imports another by its file
  name: `#import "brand.typ": brand-blue`.

  ## Errors and compilation

  Errors in a component point at the line in its file: its `.typ` file, or the `~TYPST`
  sigil in its module.

  Documents only depend on their components at runtime: changing a component recompiles
  the component, not the documents that use it. A document's components are checked when it
  renders, so listing a module that isn't a component raises `ArgumentError` then, as does
  listing two components with the same name.

  `components/` is reserved for components and their files: the `:files` option can't have
  files in it, and documents don't read it from the `:root` directory. That way, a file in
  `:files` (one a user uploaded, say) can't take the place of a component a template
  imports, or of one of its files.
  """

  alias Typsty.{Diagnostic, SyntaxError, Template}

  @name ~r/\A[A-Za-z0-9_-]+\z/

  # A component's files go with every render that lists it: past this much, compiling it
  # warns, since that costs every render something
  @large_files 8 * 1024 * 1024

  @doc """
  Returns the component's source, as a `Typsty.Template` struct. Define it with the `~TYPST`
  sigil, or leave it out and put the source in a `.typ` file next to the module.
  """
  @callback render() :: Template.t()

  @doc """
  Makes the module a component. See the module documentation.

  ## Options

  - `:name` - the component's name: documents import it from `components/<name>.typ`.
    Defaults to the last part of the module's name, in snake case. Names have letters,
    digits, underscores and hyphens.
  - `:template` - the component's `.typ` file, relative to the module's file. Defaults to
    the module's file name with the `.typ` extension. A module that defines `render/0`
    can't have one.
  - `:components` - the components it imports, as a list of modules. Documents that list
    this component get them too.
  - `:files` - the folder with the component's files (see [Files](#module-files)),
    relative to the module's file, or `false` for none. Defaults to the folder next to the
    module with its base name (`letterhead/` for `letterhead.ex`), if there is one.
  """
  defmacro __using__(opts) do
    opts = Keyword.validate!(opts, [:name, :template, :components, :files])
    {template, explicit?} = Typsty.__template_path__(opts, __CALLER__)
    components = Typsty.__components__!(opts)

    files =
      case Keyword.fetch(opts, :files) do
        {:ok, false} ->
          nil

        {:ok, path} when is_binary(path) ->
          {Path.expand(path, Path.dirname(__CALLER__.file)), true}

        {:ok, other} ->
          raise ArgumentError, "the :files option must be a path, or false, got: #{Macro.to_string(other)}"

        :error ->
          {Path.rootname(__CALLER__.file), false}
      end

    name =
      case Keyword.fetch(opts, :name) do
        {:ok, name} when is_binary(name) ->
          if not (name =~ @name) do
            raise ArgumentError,
                  "the :name option must only have letters, digits, underscores and hyphens, got: #{inspect(name)}"
          end

          name

        {:ok, other} ->
          raise ArgumentError, "the :name option must be a string, got: #{Macro.to_string(other)}"

        :error ->
          __CALLER__.module |> Module.split() |> List.last() |> Macro.underscore()
      end

    # The templates of the module's ~TYPST sigils, which record them as they expand, so that
    # the paths they read files from can be checked against the component's files
    Module.register_attribute(__CALLER__.module, :__typsty_sigils__, accumulate: true)

    quote do
      @behaviour Typsty.Component

      import Typsty.Component, only: [sigil_TYPST: 2]

      @__typsty_component__ %{
        template: unquote(template),
        explicit?: unquote(explicit?),
        files: unquote(Macro.escape(files)),
        name: unquote(name)
      }
      @before_compile Typsty.Component

      # In a function, so that documents only depend on their components at runtime
      @doc false
      def __typsty_component__, do: %{name: unquote(name), components: unquote(components)}
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    %{template: template, explicit?: explicit?, files: files, name: name} =
      Module.get_attribute(env.module, :__typsty_component__)

    Typsty.__check_not_both__!(env)
    check_render_is_public!(env)

    render_defined? = Module.defines?(env.module, {:render, 0}, :def)
    {render, sources} = source(env, template, explicit?, render_defined?, File.regular?(template))
    dir = files_dir!(env, files)
    files = read_files!(env, dir)

    # The component's sources are served at components/, and the .typ files in its folder
    # at components/<name>/
    helpers = for {relative, %Template{} = helper} <- files, do: {helper, Path.dirname("#{name}/#{relative}")}
    check_paths!(Enum.map(sources, &{&1, "."}) ++ helpers, name, dir, files)
    warn_if_large!(env, dir, files)

    quote do
      unquote(render)

      unquote_splicing(
        for {relative, _content} <- files do
          quote(do: @external_resource(unquote(Path.join(dir, relative))))
        end
      )

      @doc false
      def __typsty_files__, do: unquote(Macro.escape(files))

      # Files added to the folder, or taken out of it, recompile the module: Mix only notices
      # changes to the files it knew of
      @doc false
      def __mix_recompile__?, do: Typsty.Component.__listing__(unquote(dir)) != unquote(Enum.map(files, &elem(&1, 0)))
    end
  end

  defp check_render_is_public!(env) do
    if Module.defines?(env.module, {:render, 0}, :defp) do
      compile_error!(env, "#{inspect(env.module)} defines render/0 as private: it must be public (def, not defp)")
    end
  end

  # The component's render/0, from its .typ file, unless it defines render/0 itself
  defp source(env, template, explicit?, render_defined?, template_exists?)

  defp source(env, template, explicit?, true = _render_defined?, template_exists?) do
    if template_exists? or explicit? do
      compile_error!(
        env,
        "#{inspect(env.module)} defines render/0 and has a source file (#{Path.relative_to_cwd(template)}). " <>
          "Use one or the other"
      )
    end

    # Recompiles the module if the file is added later, to report both being defined
    render =
      quote do
        @external_resource unquote(template)
      end

    {render, env.module |> Module.get_attribute(:__typsty_sigils__) |> Enum.reverse()}
  end

  defp source(env, template, _explicit?, false, true = _template_exists?) do
    source = Typsty.__read_template__!(template, env, :component)

    render =
      quote do
        @external_resource unquote(template)

        @doc "Returns the component's source, from #{unquote(Path.relative_to_cwd(template))}."
        @spec render() :: Typsty.Template.t()
        def render, do: %Typsty.Template{source: unquote(source), file: unquote(template)}
      end

    {render, [%Template{source: source, file: template}]}
  end

  defp source(env, template, explicit?, false, false) do
    relative = Path.relative_to_cwd(template)
    reason = if explicit?, do: "the file #{relative} does not exist", else: "there is no #{relative}"

    compile_error!(
      env,
      "#{inspect(env.module)} needs a source: define render/0 using the ~TYPST sigil, or add a .typ file (#{reason})"
    )
  end

  defp compile_error!(env, description) do
    raise CompileError, file: env.file, line: env.line, description: description
  end

  # The folder with the component's files, or nil for none
  defp files_dir!(_env, nil), do: nil

  defp files_dir!(env, {dir, true = _explicit?}) do
    if not File.dir?(dir) do
      compile_error!(env, "the :files folder of #{inspect(env.module)}, #{Path.relative_to_cwd(dir)}, doesn't exist")
    end

    dir
  end

  defp files_dir!(env, {dir, false = _explicit?}) do
    # The folder next to a module with its base name can hold the modules nested in it
    # instead, which aren't the component's files
    case Enum.find(__listing__(dir), &(Path.extname(&1) in [".ex", ".exs"])) do
      nil ->
        dir

      elixir ->
        compile_error!(
          env,
          "#{Path.relative_to_cwd(dir)}, the folder for the files of #{inspect(env.module)}, has Elixir " <>
            "code in it (#{elixir}). Give the component's files another folder with the :files option, " <>
            "or none with `files: false`"
        )
    end
  end

  # The component's files, by their path in its folder: binaries, and templates for .typ
  # files, which are checked like components
  defp read_files!(_env, nil), do: []

  defp read_files!(env, dir) do
    for relative <- __listing__(dir) do
      path = Path.join(dir, relative)

      if Path.extname(relative) == ".typ" do
        {relative, %Template{source: Typsty.__read_template__!(path, env, :component), file: path}}
      else
        {relative, File.read!(path)}
      end
    end
  end

  @doc false
  # The files in a component's folder (or none, if there's no folder), by their path in it.
  # Hidden files and folders, like .DS_Store, are left out
  @spec __listing__(Path.t() | nil) :: [String.t()]
  def __listing__(nil), do: []

  def __listing__(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, dir))
    |> Enum.sort()
  end

  # The paths the component's sources read files from, written as strings, must be files in
  # its folder, if that's where they lead. Paths elsewhere (the document's files, another
  # component's) are only known when it renders
  defp check_paths!(sources, name, dir, files) do
    known = MapSet.new(files, &elem(&1, 0))

    for {template, served_in} <- sources do
      diagnostics =
        for {path, line, column} <- file_paths(template.source),
            {:own, relative} <- [resolve(served_in, path, name)],
            relative not in known do
          %Diagnostic{
            message: "#{path} isn't one of the component's files",
            hints: [missing_file_hint(relative, dir)],
            line: line,
            column: column
          }
        end

      if diagnostics != [], do: SyntaxError.raise!(diagnostics, template, :component)
    end

    :ok
  end

  defp file_paths(source) do
    case Typsty.__native_check__(&Typsty.Native.file_paths/1, source) do
      :unavailable -> []
      paths -> paths
    end
  end

  defp missing_file_hint(_relative, nil), do: "the component has no files: it's given `files: false`"

  defp missing_file_hint(relative, dir) do
    if File.dir?(dir) do
      "the component's files are in #{Path.relative_to_cwd(dir)}, which has no #{relative}"
    else
      "the component has no files: they go in #{Path.relative_to_cwd(dir)}, next to its module"
    end
  end

  # Where a path read from a source served at components/<served_in> leads, as Typst finds
  # it: {:own, path} for a file in the component's folder
  defp resolve(served_in, path, name) do
    joined = if String.starts_with?(path, "/"), do: path, else: Path.join(["components", served_in, path])

    joined
    |> String.split("/")
    |> Enum.reduce_while([], fn
      segment, segments when segment in ["", "."] -> {:cont, segments}
      "..", [_ | segments] -> {:cont, segments}
      "..", [] -> {:halt, :outside}
      segment, segments -> {:cont, [segment | segments]}
    end)
    |> case do
      :outside ->
        :elsewhere

      segments ->
        case Enum.reverse(segments) do
          ["components", ^name | [_ | _] = relative] -> {:own, Enum.join(relative, "/")}
          _elsewhere -> :elsewhere
        end
    end
  end

  defp warn_if_large!(env, dir, files) do
    size = Enum.sum_by(files, fn {_relative, content} -> content_size(content) end)

    if size > @large_files do
      IO.warn(
        "the files of #{inspect(env.module)} (in #{Path.relative_to_cwd(dir)}) take " <>
          "#{Float.round(size / (1024 * 1024), 1)} MiB, which every render that lists the component is given. " <>
          "Files that only some renders use are better given to them with the :files option",
        Macro.Env.stacktrace(env)
      )
    end
  end

  defp content_size(%Template{source: source}), do: byte_size(source)
  defp content_size(binary), do: byte_size(binary)

  @doc """
  The `~TYPST` sigil for writing a component's source inline, in `render/0`.

  Like the sigil for documents (`Typsty.sigil_TYPST/2`), it returns a `Typsty.Template`
  struct, and its source is checked when it's compiled, with the rules for components (see
  [What components can have](#module-what-components-can-have)). Components have no assigns,
  so it doesn't need an `assigns` variable.
  """
  defmacro sigil_TYPST({:<<>>, meta, [source]}, modifiers)
           when is_binary(source) and modifiers in [[], ~c"noformat"] do
    position = Typsty.__sigil_position__(meta, __CALLER__)
    template = struct!(Template, [source: source, file: __CALLER__.file] ++ position)
    Typsty.__check__!(template, :component)

    # Its paths are checked once the module's files are known (see __before_compile__/1)
    if Module.open?(__CALLER__.module) and Module.has_attribute?(__CALLER__.module, :__typsty_sigils__) do
      Module.put_attribute(__CALLER__.module, :__typsty_sigils__, template)
    end

    Macro.escape(template)
  end

  defmacro sigil_TYPST(_source, modifiers) do
    raise ArgumentError, "~TYPST only supports the noformat modifier, got: #{modifiers}"
  end

  @doc false
  # The files to give a render for its components, with the components they list: their
  # sources (`components/tables.typ`, and the .typ files in their folders) as templates, and
  # their other files (`components/tables/logo.png`) as binaries
  @spec __files__([module()]) :: {[{String.t(), Template.t()}], [{String.t(), binary()}]}
  def __files__([]), do: {[], []}

  def __files__(modules) do
    found = collect(modules, %{})
    sources = for {name, {_module, template}} <- found, do: {"components/#{name}.typ", template}

    files =
      for {name, {module, _template}} <- found, {relative, content} <- module.__typsty_files__() do
        {"components/#{name}/#{relative}", content}
      end

    {helpers, binaries} = Enum.split_with(files, &match?({_path, %Template{}}, &1))
    {Enum.sort_by(sources ++ helpers, &elem(&1, 0)), Enum.sort_by(binaries, &elem(&1, 0))}
  end

  # Components by name, with their module and template
  defp collect([], found), do: found

  defp collect([module | rest], found) do
    %{name: name, components: components} = info!(module)

    case found do
      %{^name => {^module, _template}} ->
        collect(rest, found)

      %{^name => {other, _template}} ->
        raise ArgumentError,
              "#{inspect(other)} and #{inspect(module)} are both components named #{inspect(name)} " <>
                "(imported from components/#{name}.typ). Give one of them another name with " <>
                "`use Typsty.Component, name: \"...\"`"

      _ ->
        collect(components ++ rest, Map.put(found, name, {module, template!(module)}))
    end
  end

  defp info!(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        if function_exported?(module, :__typsty_component__, 0) do
          module.__typsty_component__()
        else
          raise ArgumentError,
                "#{inspect(module)} isn't a component: components are modules with `use Typsty.Component`"
        end

      {:error, _reason} ->
        raise ArgumentError, "#{inspect(module)} isn't a component: there's no module named #{inspect(module)}"
    end
  end

  defp template!(module) do
    case module.render() do
      %Template{source: source} = template when is_binary(source) ->
        template

      other ->
        raise ArgumentError, "#{inspect(module)}.render/0 must return a ~TYPST template, got: #{inspect(other)}"
    end
  end
end
