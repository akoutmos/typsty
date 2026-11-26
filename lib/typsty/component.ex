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

  Images and other files are best passed as arguments too, from the document's `:files`,
  like the letterhead's `logo` above. (Paths in a component are relative to
  `components/`, so a component that reads a file itself needs an absolute path, such as
  `image("/logo.png")`.)

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

  `components/` is reserved for components: the `:files` option can't have files in it, and
  documents don't read it from the `:root` directory. That way, a file in `:files` (one a
  user uploaded, say) can't take the place of a component a template imports.
  """

  alias Typsty.Template

  @name ~r/\A[A-Za-z0-9_-]+\z/

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
  """
  defmacro __using__(opts) do
    opts = Keyword.validate!(opts, [:name, :template, :components])
    {template, explicit?} = Typsty.__template_path__(opts, __CALLER__)
    components = Typsty.__components__!(opts)

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

    quote do
      @behaviour Typsty.Component

      import Typsty.Component, only: [sigil_TYPST: 2]

      @__typsty_component__ {unquote(template), unquote(explicit?)}
      @before_compile Typsty.Component

      # In a function, so that documents only depend on their components at runtime
      @doc false
      def __typsty_component__, do: %{name: unquote(name), components: unquote(components)}
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    {template, explicit?} = Module.get_attribute(env.module, :__typsty_component__)

    Typsty.__check_not_both__!(env)
    check_render_is_public!(env)

    source(env, template, explicit?, Module.defines?(env.module, {:render, 0}, :def), File.regular?(template))
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
    quote do
      @external_resource unquote(template)
    end
  end

  defp source(env, template, _explicit?, false, true = _template_exists?) do
    source = Typsty.__read_template__!(template, env, :component)

    quote do
      @external_resource unquote(template)

      @doc "Returns the component's source, from #{unquote(Path.relative_to_cwd(template))}."
      @spec render() :: Typsty.Template.t()
      def render, do: %Typsty.Template{source: unquote(source), file: unquote(template)}
    end
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
    Macro.escape(template)
  end

  defmacro sigil_TYPST(_source, modifiers) do
    raise ArgumentError, "~TYPST only supports the noformat modifier, got: #{modifiers}"
  end

  @doc false
  # The files to give a render for its components, with the components they list: their
  # paths (`components/tables.typ`) and templates
  @spec __files__([module()]) :: [{String.t(), Template.t()}]
  def __files__([]), do: []

  def __files__(modules) do
    modules
    |> collect(%{})
    |> Enum.map(fn {name, {_module, template}} -> {"components/#{name}.typ", template} end)
    |> Enum.sort_by(&elem(&1, 0))
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
