defmodule Typsty.DocumentTest do
  use ExUnit.Case, async: true

  alias Typsty.{RenderError, SyntaxError, Template}
  alias Typsty.Test.{Greeting, Invoice, Receipt}

  describe "a module with render/1" do
    test "renders the ~TYPST sigil with the assigns render/1 computed" do
      assert {:ok, "%PDF-" <> _} = Greeting.to_pdf(%{name: "World", items: ["one", "two"]})
      assert {:ok, [<<137, "PNG", _::binary>>]} = Greeting.to_png(%{name: "World", items: []})
      assert {:ok, ["<svg" <> _]} = Greeting.to_svg(%{name: "World", items: []})
    end

    test "render/1 returns a template with the sigil's location" do
      assert %Template{assigns: %{name: "World"}, file: file, line: 9, column: 5, indentation: 4} =
               Greeting.render(%{name: "World"})

      assert Path.basename(file) == "greeting.ex"
    end

    test "points render errors at the line in the module" do
      assert {:error, %RenderError{diagnostics: [diagnostic]}} = Greeting.to_pdf(%{name: "World", items: 1})
      assert diagnostic.message =~ "cannot loop over integer"
      assert diagnostic.file == "test/support/documents/greeting.ex"
      assert {diagnostic.line, diagnostic.column} == {12, 18}
    end

    test "the bang variants raise" do
      assert "%PDF-" <> _ = Greeting.to_pdf!(%{name: "World", items: []})
      assert [_png] = Greeting.to_png!(%{name: "World", items: []})
      assert [_svg] = Greeting.to_svg!(%{name: "World", items: []})

      error = assert_raise RenderError, fn -> Greeting.to_pdf!(%{name: "World", items: 1}) end
      assert Exception.message(error) =~ "test/support/documents/greeting.ex:12:18: cannot loop over integer"
    end
  end

  describe "a module with a colocated template" do
    test "renders the .typ file next to the module" do
      items = [%{name: "Widget", price: Decimal.new("19.99")}, %{name: "Gadget", price: Decimal.new("5.01")}]
      assert {:ok, "%PDF-" <> _} = Invoice.to_pdf(%{number: 1042, items: items})
    end

    test "points render errors at the line in the template file" do
      assert {:error, %RenderError{diagnostics: [diagnostic]}} = Invoice.to_pdf(%{number: 1042, items: [%{name: "x"}]})
      assert diagnostic.file == "test/support/documents/invoice.typ"
      assert diagnostic.line == 8
    end

    test "renders the template given with the :template option, with overridden defaults" do
      assert {:ok, "%PDF-" <> _} = Receipt.to_pdf(%{customer: "Alex"})
      assert "%PDF-" <> _ = Receipt.to_pdf!(%{customer: "Alex"})

      assert {:error, %RenderError{diagnostics: [diagnostic]}} =
               Receipt.to_pdf(%{customer: "Alex"}, files: %{})

      assert diagnostic.message =~ "note.txt"
    end
  end

  describe "compile-time checks" do
    @describetag :tmp_dir

    test "raises SyntaxError for invalid syntax in a sigil, pointing at the module's line", %{tmp_dir: dir} do
      file = Path.join(dir, "bad_sigil.ex")

      File.write!(file, """
      defmodule Typsty.Test.BadSigil do
        use Typsty

        def render(assigns) do
          ~TYPST\"\"\"
          = Fine
          #let x = (1, 2
          \"\"\"
        end
      end
      """)

      error = assert_raise SyntaxError, fn -> Code.compile_file(file) end
      assert error.line == 7
      assert error.column == 14
      assert error.file == Path.relative_to_cwd(file)
      assert Exception.message(error) =~ "bad_sigil.ex:7:14: unclosed delimiter"
      # The caret is under the unclosed parenthesis
      assert Exception.message(error) =~ "\n    #let x = (1, 2\n" <> String.duplicate(" ", 13) <> "^"
    end

    test "raises SyntaxError for invalid syntax in a single-line sigil", %{tmp_dir: dir} do
      assert_raise SyntaxError, ~r/single_line.ex:3:44: unclosed delimiter/, fn ->
        compile!(dir, "single_line.ex", """
        defmodule Typsty.Test.SingleLine do
          use Typsty
          def render(assigns), do: ~TYPST"#let x = (1, 2"
        end
        """)
      end
    end

    test "raises SyntaxError for invalid syntax in a template file", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "bad_file.typ"), "Fine\n\n#for x in (1, 2) [\n")

      error =
        assert_raise SyntaxError, fn ->
          compile!(dir, "bad_file.ex", "defmodule Typsty.Test.BadFile do\n  use Typsty\nend\n")
        end

      assert {Path.basename(error.file), error.line} == {"bad_file.typ", 3}
    end

    test "requires a template", %{tmp_dir: dir} do
      assert_raise CompileError, ~r/needs a template.*there is no .*no_template.typ/, fn ->
        compile!(dir, "no_template.ex", "defmodule Typsty.Test.NoTemplate do\n  use Typsty\nend\n")
      end

      assert_raise CompileError, ~r/the template .*missing.typ does not exist/, fn ->
        compile!(dir, "missing.ex", ~s|defmodule Typsty.Test.Missing do\n  use Typsty, template: "missing.typ"\nend\n|)
      end
    end

    test "doesn't allow both render/1 and a template file", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "both.typ"), "Hello")

      assert_raise CompileError, ~r/defines render\/1 and has a template/, fn ->
        compile!(dir, "both.ex", """
        defmodule Typsty.Test.Both do
          use Typsty
          def render(assigns), do: ~TYPST"Hello"
        end
        """)
      end
    end

    test "requires render/1 to be public, and not combined with a :template", %{tmp_dir: dir} do
      assert_raise CompileError, ~r/defines render\/1 as private: it must be public/, fn ->
        compile!(dir, "private.ex", """
        defmodule Typsty.Test.Private do
          use Typsty
          defp render(assigns), do: ~TYPST"Hello"
          def preview, do: render(%{})
        end
        """)
      end

      assert_raise CompileError, ~r/defines render\/1 and has a template/, fn ->
        compile!(dir, "explicit.ex", """
        defmodule Typsty.Test.Explicit do
          use Typsty, template: "missing.typ"
          def render(assigns), do: ~TYPST"Hello"
        end
        """)
      end
    end

    test "the sigil requires assigns", %{tmp_dir: dir} do
      assert_raise CompileError, ~r/~TYPST requires a variable named "assigns"/, fn ->
        compile!(dir, "no_assigns.ex", """
        defmodule Typsty.Test.NoAssigns do
          use Typsty
          def render(_assigns), do: ~TYPST"Hello"
        end
        """)
      end
    end

    test "the sigil only supports the noformat modifier" do
      assert_raise ArgumentError, ~r/only supports the noformat modifier/, fn ->
        Code.eval_string(~S|import Typsty; assigns = %{}; ~TYPST"Hello"x|)
      end

      assert {%Template{source: "Hello"}, _binding} =
               Code.eval_string(~S|import Typsty; assigns = %{}; ~TYPST"Hello"noformat|)
    end
  end

  describe "render/1 returning something else" do
    test "raises ArgumentError" do
      defmodule NotATemplate do
        use Typsty
        def render(_assigns), do: "= Hello"
      end

      assert_raise ArgumentError, ~r/render\/1 must return a ~TYPST template, got: "= Hello"/, fn ->
        NotATemplate.to_pdf(%{})
      end
    end
  end

  defp compile!(dir, name, source) do
    file = Path.join(dir, name)
    File.write!(file, source)
    Code.compile_file(file)
  end
end
