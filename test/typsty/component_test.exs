defmodule Typsty.ComponentTest.Box do
  use Typsty.Component

  def render do
    ~TYPST"#let boxed(body) = rect(fill: luma(230), inset: 4pt, body)"
  end
end

# Two components that list each other
defmodule Typsty.ComponentTest.Ping do
  use Typsty.Component, components: [Typsty.ComponentTest.Pong]
  def render, do: ~TYPST"#let ping = 1"
end

defmodule Typsty.ComponentTest.Pong do
  use Typsty.Component, components: [Typsty.ComponentTest.Ping]
  def render, do: ~TYPST"#let pong = 2"
end

# The same name as Typsty.Test.Tables
defmodule Typsty.ComponentTest.OtherTables do
  use Typsty.Component, name: "line-items"
  def render, do: ~TYPST"#let line-items = none"
end

defmodule Typsty.ComponentTest.NotATemplate do
  use Typsty.Component
  def render, do: "#let x = 1"
end

defmodule Typsty.ComponentTest do
  use ExUnit.Case, async: true

  alias Typsty.ComponentTest.{Box, NotATemplate, OtherTables, Ping}
  alias Typsty.{Diagnostic, RenderError, SyntaxError, Template}
  alias Typsty.Test.{Brand, Letterhead, Statement, Tables}

  import Typsty.Test.Helpers, only: [compile!: 3, position: 2]

  @tables "test/support/components/tables.ex"

  @statement %{number: 7, items: [%{name: "Widget", price: 25}], signed_by: "Alex"}

  describe "rendering" do
    test "documents render the components they list, with the components those list" do
      assert {:ok, "%PDF-" <> _} = Statement.to_pdf(@statement)
      assert {:ok, [_svg]} = Statement.to_svg(@statement)
    end

    test "a component renders what the same code inline does" do
      inline = "#let boxed(body) = rect(fill: luma(230), inset: 4pt, body)\n#boxed[Hello]"
      imported = ~s(#import "components/box.typ": boxed\n#boxed[Hello])

      assert {:ok, _svgs} = expected = Typsty.to_svg(inline)
      assert Typsty.to_svg(imported, %{}, components: [Box]) == expected
    end

    test "the :components option adds to the module's components" do
      assert {:ok, _} = Statement.to_svg(@statement, components: [Box])

      assert {:ok, _} =
               Typsty.to_svg(~s|#import "components/brand.typ": blue\n#text(fill: blue)[Hi]|, %{}, components: [Brand])
    end

    test "a component listed more than once, or by components that list each other, is given once" do
      assert {:ok, _} = Typsty.to_svg("Hi", %{}, components: [Letterhead, Brand, Letterhead])

      source = ~s|#import "components/ping.typ": ping\n#import "components/pong.typ": pong\n#(ping + pong)|
      assert {:ok, _} = Typsty.to_svg(source, %{}, components: [Ping])
    end

    test "works in a Typsty.Pool" do
      pool = Module.concat(__MODULE__, "Pool#{System.unique_integer([:positive])}")
      start_supervised!({Typsty.Pool, name: pool, size: 1})

      assert {:ok, _svgs} = expected = Statement.to_svg(@statement)
      assert Statement.to_svg(@statement, pool: pool) == expected

      assert {:error, %RenderError{diagnostics: [diagnostic]}} =
               Statement.to_svg(%{@statement | items: [%{name: "Widget"}]}, pool: pool)

      assert {diagnostic.file, diagnostic.line} == {@tables, elem(position(@tables, "price]"), 0)}
    end
  end

  describe "errors" do
    test "point at the line in a component's sigil, with the call in the document" do
      assert {:error, %RenderError{diagnostics: [diagnostic]}} =
               Statement.to_pdf(%{@statement | items: [%{name: "Widget"}]})

      assert diagnostic.message =~ ~s(dictionary does not contain key "price")
      # At the field that isn't there
      assert {diagnostic.file, diagnostic.line, diagnostic.column} ==
               Tuple.insert_at(position(@tables, "price]"), 0, @tables)

      {call, _column} = position("test/support/documents/statement.ex", "#line-items(assigns.items)")
      assert Enum.any?(diagnostic.trace, &match?(%{file: "test/support/documents/statement.ex", line: ^call}, &1))
    end

    test "point at the line in a component's .typ file" do
      assert {:error, %RenderError{diagnostics: [diagnostic]}} = Statement.to_pdf(%{@statement | signed_by: 1})
      letterhead = "test/support/components/letterhead.typ"
      assert {diagnostic.file, diagnostic.line} == {letterhead, elem(position(letterhead, "#name.first()"), 0)}
    end

    test "say that components don't see the document's assigns" do
      source = ~s|#import "components/line-items.typ": uses-assigns\n#uses-assigns()|

      assert {:error, %RenderError{diagnostics: [diagnostic]}} =
               Typsty.to_pdf(source, %{total: 1}, components: [Tables])

      assert diagnostic.message == "unknown variable: assigns"
      assert {diagnostic.file, diagnostic.line} == {@tables, elem(position(@tables, "assigns.total"), 0)}
      assert List.last(diagnostic.hints) =~ "components don't see the document's assigns"
    end

    test "say how to give a component that a template imports but wasn't given" do
      assert {:error, %RenderError{diagnostics: [diagnostic]}} =
               Typsty.to_pdf(~s(#import "components/brand.typ": blue))

      assert diagnostic.message =~
               "/components/brand.typ is not one of the render's components, or one of their files (components/ only " <>
                 "has the components given to the render, and their files). Add the component's module to " <>
                 "`use Typsty, components: [...]`, or to the :components option"

      # The hint for a document module's template doesn't apply to Typst source
      refute Enum.any?(diagnostic.hints, &(&1 =~ "document module"))
    end
  end

  describe "components/" do
    @describetag :tmp_dir

    test "isn't read from the :root directory", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "components"))
      File.write!(Path.join(dir, "components/brand.typ"), "#let blue = red")
      File.write!(Path.join(dir, "components/line-items.typ"), "#let line-items(items) = [Not the component]")

      assert {:error, %RenderError{diagnostics: [diagnostic]}} =
               Typsty.to_pdf(~s(#import "components/brand.typ": blue), %{}, root: dir)

      assert diagnostic.message =~ "is not one of the render's components"

      # The component, rather than the file in the directory
      assert {:ok, _svgs} = expected = Statement.to_svg(@statement)
      assert Statement.to_svg(@statement, root: dir) == expected
    end

    @tag :unix
    test "isn't read from the :root directory under another name", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "components"))
      File.write!(Path.join(dir, "components/note.txt"), "from the directory")
      File.ln_s!(Path.join(dir, "components"), Path.join(dir, "linked"))

      # Through a symbolic link, and in another case on a file system that ignores case
      names =
        if File.exists?(Path.join(dir, "COMPONENTS")), do: ["linked", "Components", "COMPONENTS"], else: ["linked"]

      for name <- names do
        assert {:error, %RenderError{diagnostics: [%{message: message}]}} =
                 Typsty.to_pdf(~s|#read("#{name}/note.txt")|, %{}, root: dir)

        assert message =~ "/#{name}/note.txt is not one of the render's components"
      end

      # Other directories are read as usual
      File.mkdir_p!(Path.join(dir, "notes"))
      File.write!(Path.join(dir, "notes/note.txt"), "from the directory")
      assert {:ok, _pdf} = Typsty.to_pdf(~s|#assert.eq(read("notes/note.txt"), "from the directory")|, %{}, root: dir)
    end

    test "can't have files in :files" do
      for path <- [
            "components/brand.typ",
            "/components/brand.typ",
            "./components//x.png",
            "a/../components/x",
            "components"
          ] do
        assert_raise ArgumentError, ~r/the path .* is in components\/, which is reserved for components/, fn ->
          Typsty.to_pdf("x", %{}, files: %{path => "#let blue = red"})
        end
      end

      assert {:ok, _} = Typsty.to_svg("x", %{}, files: %{"components.typ" => "", "my/components/x.typ" => ""})

      assert_raise ArgumentError, ~r/leads outside the project root/, fn ->
        Typsty.to_pdf("x", %{}, files: %{"../components/x.typ" => ""})
      end
    end
  end

  describe "the :components option" do
    test "must be a list of components" do
      for components <- [Brand, ["brand"], [nil]] do
        assert_raise ArgumentError,
                     ~r/invalid value for :components option: expected a list of component modules/,
                     fn ->
                       Typsty.to_pdf("x", %{}, components: components)
                     end
      end

      assert_raise ArgumentError,
                   "Typsty.Test.Statement isn't a component: components are modules with `use Typsty.Component`",
                   fn ->
                     Typsty.to_pdf("x", %{}, components: [Statement])
                   end

      assert_raise ArgumentError,
                   ~r/Typsty.Test.Nope isn't a component: there's no module named Typsty.Test.Nope/,
                   fn ->
                     Typsty.to_pdf("x", %{}, components: [Typsty.Test.Nope])
                   end
    end

    test "can't have two components with the same name" do
      assert_raise ArgumentError,
                   ~r/Typsty.Test.Tables and Typsty.ComponentTest.OtherTables are both components named "line-items" \(imported from components\/line-items.typ\)/,
                   fn -> Statement.to_pdf(@statement, components: [OtherTables]) end
    end

    test "requires render/0 to return a template" do
      assert_raise ArgumentError, ~r/NotATemplate.render\/0 must return a ~TYPST template, got: "#let x = 1"/, fn ->
        Typsty.to_pdf("x", %{}, components: [NotATemplate])
      end
    end
  end

  describe "a component module" do
    test "render/0 returns its source, with the sigil's location" do
      assert %Template{source: "// The brand's colors" <> _, file: file, line: 7, column: 5, indentation: 4} =
               Brand.render()

      assert Path.basename(file) == "brand.ex"

      assert %Template{source: "#import \"brand.typ\"" <> _, file: file, line: 1} = Letterhead.render()
      assert Path.basename(file) == "letterhead.typ"
    end

    test "is named after the last part of its module, or the :name option" do
      assert Box.__typsty_component__() == %{name: "box", components: []}
      assert Tables.__typsty_component__() == %{name: "line-items", components: []}
      assert Letterhead.__typsty_component__() == %{name: "letterhead", components: [Brand]}
    end
  end

  describe "compile-time checks" do
    @describetag :tmp_dir

    test "refuse anything but definitions and imports at the top level of a sigil", %{tmp_dir: dir} do
      error =
        assert_raise SyntaxError, fn ->
          compile!(dir, "partial.ex", """
          defmodule Typsty.Test.Partial do
            use Typsty.Component

            def render do
              ~TYPST\"\"\"
              #let a = 1
              Hello #a
              #set text(red)
              \"\"\"
            end
          end
          """)
        end

      assert error.kind == :component
      assert {Path.basename(error.file), error.line, error.column} == {"partial.ex", 7, 5}

      assert [%Diagnostic{line: 7, hints: [content_hint]}, %Diagnostic{line: 8, hints: [rule_hint]}] =
               error.diagnostics

      assert content_hint =~ "content outside a function doesn't appear in the documents that import the component"
      assert rule_hint =~ "a set or show rule outside a function only applies to the component's own file"

      message = Exception.message(error)

      assert message =~
               "invalid component: #{error.file}:7:5: a component can only define things (with `#let`) and import them (with `#import`)"

      assert message =~ "\n    Hello #a\n    ^"
      assert message =~ "#{error.file}:8:5: a component can only define things"
    end

    test "refuse anything but definitions and imports at the top level of a .typ file", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "include.typ"), "#let a = 1\n\n#include \"other.typ\"\n")

      error =
        assert_raise SyntaxError, fn ->
          compile!(dir, "include.ex", "defmodule Typsty.Test.Include do\n  use Typsty.Component\nend\n")
        end

      assert {error.kind, Path.basename(error.file), error.line, error.column} == {:component, "include.typ", 3, 1}
    end

    test "refuse reading sys.inputs", %{tmp_dir: dir} do
      error =
        assert_raise SyntaxError, fn ->
          compile!(dir, "inputs.ex", """
          defmodule Typsty.Test.Inputs do
            use Typsty.Component
            def render, do: ~TYPST"#let total() = sys.inputs.assigns.total"
          end
          """)
        end

      assert {error.kind, error.line, error.column} == {:component, 3, 41}
      assert Exception.message(error) =~ "a component can't read `sys.inputs`, which holds the document's assigns"
    end

    test "refuse sys used other than to read its fields, and eval", %{tmp_dir: dir} do
      for {code, message} <- [
            {"#let total() = (sys).inputs.assigns.total", "a component can't read `sys.inputs`"},
            {"#let s = sys", "a component can't read `sys.inputs`"},
            {~S|#let total() = eval("sys.inputs.assigns.total")|,
             "a component can't use `eval`, which can read `sys.inputs`"}
          ] do
        error =
          assert_raise SyntaxError, fn ->
            compile!(dir, "values.ex", """
            defmodule Typsty.Test.Values do
              use Typsty.Component
              def render, do: ~TYPST|#{code}|
            end
            """)
          end

        assert error.kind == :component
        assert Exception.message(error) =~ message
      end

      # Its other fields are fine
      compile!(
        dir,
        "version.ex",
        ~s|defmodule Typsty.Test.Version do\n  use Typsty.Component\n  def render, do: ~TYPST"#let v = sys.version"\nend\n|
      )
    end

    test "report syntax errors as syntax errors", %{tmp_dir: dir} do
      error =
        assert_raise SyntaxError, fn ->
          compile!(dir, "syntax.ex", """
          defmodule Typsty.Test.Syntax do
            use Typsty.Component
            def render, do: ~TYPST"#let x = (1, 2"
          end
          """)
        end

      assert error.kind == :syntax
      assert Exception.message(error) =~ "invalid Typst syntax: "
    end

    test "require a source", %{tmp_dir: dir} do
      assert_raise CompileError,
                   ~r/needs a source: define render\/0 using the ~TYPST sigil, or add a .typ file \(there is no .*no_source.typ\)/,
                   fn ->
                     compile!(dir, "no_source.ex", "defmodule Typsty.Test.NoSource do\n  use Typsty.Component\nend\n")
                   end

      assert_raise CompileError, ~r/the file .*missing_source.typ does not exist/, fn ->
        compile!(
          dir,
          "missing.ex",
          ~s|defmodule Typsty.Test.MissingSource do\n  use Typsty.Component, template: "missing_source.typ"\nend\n|
        )
      end
    end

    test "don't allow both render/0 and a .typ file, or a private render/0", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "both_sources.typ"), "#let a = 1")

      assert_raise CompileError, ~r/defines render\/0 and has a source file/, fn ->
        compile!(dir, "both_sources.ex", """
        defmodule Typsty.Test.BothSources do
          use Typsty.Component
          def render, do: ~TYPST"#let a = 1"
        end
        """)
      end

      assert_raise CompileError, ~r/defines render\/0 as private: it must be public/, fn ->
        compile!(dir, "private_render.ex", """
        defmodule Typsty.Test.PrivateRender do
          use Typsty.Component
          defp render, do: ~TYPST"#let a = 1"
          def other, do: render()
        end
        """)
      end
    end

    test "don't allow a module to be both a document and a component", %{tmp_dir: dir} do
      assert_raise CompileError,
                   ~r/uses both Typsty and Typsty.Component: a module is a document or a component, not both/,
                   fn ->
                     compile!(dir, "both_kinds.ex", """
                     defmodule Typsty.Test.BothKinds do
                       use Typsty
                       use Typsty.Component
                       def render(assigns), do: %Typsty.Template{source: "", assigns: assigns}
                       def render, do: %Typsty.Template{source: ""}
                     end
                     """)
                   end
    end

    test "check the options", %{tmp_dir: dir} do
      assert_raise ArgumentError,
                   ~r/the :name option must only have letters, digits, underscores and hyphens, got: "a\/b"/,
                   fn ->
                     compile!(
                       dir,
                       "slash.ex",
                       ~s|defmodule Typsty.Test.Slash do\n  use Typsty.Component, name: "a/b"\nend\n|
                     )
                   end

      assert_raise ArgumentError, ~r/the :name option must be a string, got: :brand/, fn ->
        compile!(
          dir,
          "atom_name.ex",
          ~s|defmodule Typsty.Test.AtomName do\n  use Typsty.Component, name: :brand\nend\n|
        )
      end

      for kind <- ["Typsty", "Typsty.Component"] do
        assert_raise ArgumentError,
                     ~r/the :components option must be a list of component modules, got: Typsty.Test.Brand/,
                     fn ->
                       compile!(dir, "not_a_list.ex", """
                       defmodule Typsty.Test.NotAList do
                         use #{kind}, components: Typsty.Test.Brand
                       end
                       """)
                     end
      end
    end

    test "the sigil takes the noformat modifier, and no others", %{tmp_dir: dir} do
      [{module, _binary}] =
        compile!(dir, "noformat.ex", """
        defmodule Typsty.Test.Noformat do
          use Typsty.Component
          def render, do: ~TYPST"#let   a = 1"noformat
        end
        """)

      assert module.render().source == "#let   a = 1"

      assert_raise ArgumentError, ~r/~TYPST only supports the noformat modifier/, fn ->
        compile!(dir, "modifier.ex", """
        defmodule Typsty.Test.Modifier do
          use Typsty.Component
          def render, do: ~TYPST"#let a = 1"x
        end
        """)
      end
    end
  end
end
