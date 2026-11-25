defmodule TypstyTest do
  use ExUnit.Case, async: true

  alias Typsty.{Diagnostic, RenderError, Template}

  # A 1x1 transparent PNG
  @png Base.decode64!("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=")

  describe "to_pdf/3" do
    test "renders Typst source as a PDF" do
      assert {:ok, "%PDF-" <> _} = Typsty.to_pdf("= Hello")
    end

    test "passes the assigns in the assigns dictionary" do
      assert {:ok, _pdf} = Typsty.to_pdf(~s|#assert.eq(assigns.name, "World")|, %{name: "World"})
      assert {:ok, _pdf} = Typsty.to_pdf(~s|#assert.eq(assigns.name, "World")|, %{"name" => "World"})
      assert {:ok, _pdf} = Typsty.to_pdf(~s|#assert.eq(assigns, (:))|)
    end

    test "takes any key, including ones that aren't Typst identifiers" do
      source = ~S"""
      #assert.eq(assigns.invoice-number, 7)
      #assert.eq(assigns.at("invoice number"), 8)
      #assert.eq(assigns.for, 9)
      #assert.eq(assigns.at("_"), 10)
      #assert.eq(assigns.at("missing", default: none), none)
      """

      assigns = %{"invoice-number" => 7, "invoice number" => 8, for: 9, _: 10}
      assert {:ok, _pdf} = Typsty.to_pdf(source, assigns)
    end

    test "doesn't shadow anything in Typst" do
      source = ~S"""
      #assert.eq(type(title), function)
      #assert.eq(assigns.title, "My title")
      #title[#assigns.title]
      #import "helper.typ": shout
      #assert.eq(shout("x"), "X")
      """

      # Imported files don't see the assigns variable, but can read sys.inputs
      helper = ~S"""
      #let shout(text) = { assert.eq(sys.inputs.assigns.title, "My title"); upper(text) }
      """

      assert {:ok, _pdf} = Typsty.to_pdf(source, %{title: "My title", upper: "x"}, files: %{"helper.typ" => helper})
    end

    test "points errors at lines of the template, not counting the line that binds the assigns" do
      assert {:error, %RenderError{diagnostics: [diagnostic]}} =
               Typsty.to_pdf("first line\nsecond #assigns.nmae", %{name: "World"})

      assert %Diagnostic{severity: :error, file: nil, line: 2, column: 17} = diagnostic
      assert diagnostic.message =~ ~s(dictionary does not contain key "nmae")
    end

    test "hints at assigns that weren't given" do
      hint =
        ~s|there's no "customer" in the assigns. Pass it from Elixir, or read it with | <>
          ~s|`assigns.at("customer", default: none)` if it's optional|

      for source <- ["#assigns.customer.name", ~S|#assigns.at("customer")|, "#let (customer,) = assigns"] do
        assert {:error, %RenderError{diagnostics: [diagnostic]}} = Typsty.to_pdf(source, %{name: "World"})
        assert diagnostic.hints == [hint], source
      end

      # Other dictionaries are left alone
      for source <- ["#let d = (a: 1)\n#d.customer", "#assigns.items.first().customer"] do
        assert {:error, %RenderError{diagnostics: [diagnostic]}} = Typsty.to_pdf(source, %{items: [%{}]})
        assert diagnostic.hints == [], source
      end
    end

    test "lets a template give assigns short names, and pass them to components" do
      source = ~S"""
      #import "components.typ": greeting
      #let (name, items) = assigns
      #assert.eq(greeting(name), "Hello World")
      #assert.eq(items.len(), 2)
      """

      components = ~S|#let greeting(name) = "Hello " + name|

      assert {:ok, _pdf} =
               Typsty.to_pdf(source, %{name: "World", items: [1, 2]}, files: %{"components.typ" => components})
    end

    test "returns errors with hints" do
      assert {:error, %RenderError{diagnostics: [diagnostic]}} = Typsty.to_pdf("#let a = 1\n#let b = 2\n#a-b")
      assert diagnostic.message == "unknown variable: a-b"
      assert [hint | _] = diagnostic.hints
      assert hint =~ "subtraction"
      assert Exception.message(%RenderError{diagnostics: [diagnostic]}) =~ "\n  hint: "
    end

    test "merges the assigns into a template's assigns" do
      template = %Template{source: "#assert.eq((assigns.a, assigns.b), (1, 3))", assigns: %{a: 1, b: 2}}
      assert {:ok, _pdf} = Typsty.to_pdf(template, %{b: 3})
    end

    test "conforms to PDF standards, which are checked before rendering" do
      # PDF/A requires a date, which is the time of the render by default
      assert {:ok, pdf} = Typsty.to_pdf("#set document(title: [Doc])\nHello", %{}, pdf_standards: ["a-2b"])
      assert pdf =~ "pdfaid"

      assert {:error, %RenderError{diagnostics: [%{message: "PDF/A-2b error: missing document date"}]}} =
               Typsty.to_pdf("#set document(title: [Doc], date: none)\nHello", %{}, pdf_standards: ["a-2b"])

      assert_raise ArgumentError, ~r/invalid :pdf_standards option/, fn ->
        Typsty.to_pdf("Hello", %{}, pdf_standards: ["a-2b", "a-3b"])
      end
    end

    test "raises for assigns that aren't a map, which keeps options from being taken for them" do
      assert_raise ArgumentError,
                   ~r/the assigns must be a map, got a list: \[ppi: 300\]. Options go after the assigns/,
                   fn ->
                     Typsty.to_png("x", ppi: 300)
                   end

      assert_raise ArgumentError, ~r/the assigns must be a map, got a URI struct/, fn ->
        Typsty.to_pdf("x", URI.parse("https://typst.app"))
      end
    end

    test "takes the first of an option given more than once, like Keyword.get/2" do
      assert {:ok, [small]} = Typsty.to_png("#set page(width: 1in, height: 1in)", %{}, ppi: 72, ppi: 300)
      assert {:ok, [large]} = Typsty.to_png("#set page(width: 1in, height: 1in)", %{}, ppi: 300, ppi: 72)
      assert byte_size(large) > byte_size(small)
    end

    test "raises for templates that aren't Typst source" do
      assert_raise ArgumentError, ~r/the template's source isn't valid UTF-8/, fn ->
        Typsty.to_pdf(%Template{source: <<0xFF>>})
      end

      assert_raise ArgumentError, ~r/the template's source must be a string, got: nil/, fn ->
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(Typsty, :to_pdf, [%Template{source: nil}])
      end

      assert_raise ArgumentError, ~r/:files option: expected paths that are valid UTF-8/, fn ->
        Typsty.to_pdf("x", %{}, files: [{<<0xFF>>, "x"}])
      end

      assert_raise ArgumentError, ~r/the Typst source isn't valid UTF-8/, fn -> Typsty.to_pdf(<<"= Hi ", 0xFF>>) end
      assert_raise ArgumentError, ~r/the Typst source isn't valid UTF-8/, fn -> Typsty.validate(<<0xFF>>) end
      assert_raise ArgumentError, ~r/the Typst source isn't valid UTF-8/, fn -> Typsty.format(<<0xFF>>) end

      assert_raise ArgumentError,
                   ~r/To render a document module, call its functions, like Typsty.Test.Greeting.to_pdf/,
                   fn ->
                     # Through apply/3, which keeps Elixir's type checker from flagging the call
                     # credo:disable-for-next-line Credo.Check.Refactor.Apply
                     apply(Typsty, :to_pdf, [Typsty.Test.Greeting, %{}])
                   end
    end

    test "ignores a byte order mark at the start of the template" do
      assert {:ok, _pdf} = Typsty.to_pdf("\uFEFF= Title\n#context assert.eq(query(heading).len(), 1)")
      assert Typsty.validate("\uFEFF= Title") == :ok
    end

    test "raises for invalid options, saying which one" do
      assert_raise ArgumentError, ~r/^unknown options \[:bogus\], valid options are: \[:files, :root/, fn ->
        Typsty.to_pdf("x", %{}, bogus: 1)
      end

      # Config-only options can't be given to a render
      assert_raise ArgumentError, ~r/^unknown options \[:max_concurrent_renders\]/, fn ->
        Typsty.to_pdf("x", %{}, max_concurrent_renders: 2)
      end

      assert_raise ArgumentError, "invalid value for :ppi option: expected a positive number, got: 0", fn ->
        Typsty.to_png("x", %{}, ppi: 0)
      end

      assert_raise ArgumentError,
                   ~s|invalid value for :font_paths option: expected a list of paths, got: "fonts"|,
                   fn ->
                     Typsty.to_pdf("x", %{}, font_paths: "fonts")
                   end

      assert_raise ArgumentError, ~r/^invalid list in :pdf_standards option: .* expected one of \["1.4"/, fn ->
        Typsty.to_pdf("x", %{}, pdf_standards: ["z-1"])
      end

      assert_raise ArgumentError, "the options must be a keyword list, got: %{ppi: 1}", fn ->
        Typsty.to_pdf("x", %{}, %{ppi: 1})
      end

      assert_raise ArgumentError, "invalid value for :root option: expected a path (a string) or nil, got: :foo", fn ->
        Typsty.to_pdf("x", %{}, root: :foo)
      end

      assert_raise ArgumentError,
                   ~r/^invalid value for :timeout option: expected a positive integer .* \(at most 4294967295\)/,
                   fn ->
                     Typsty.to_pdf("x", %{}, timeout: 5_000_000_000)
                   end

      assert_raise ArgumentError,
                   ~r/:pool option \(or the :pool config\) names no running Typsty.Pool: :no_such_pool/,
                   fn ->
                     Typsty.to_pdf("x", %{}, pool: :no_such_pool)
                   end

      assert_raise ArgumentError,
                   ~r/^invalid value for :pool option: expected the name or pid of a Typsty.Pool, or nil/,
                   fn ->
                     Typsty.to_pdf("x", %{}, pool: false)
                   end

      assert_raise ArgumentError, ~r/^unknown options \[:indnet\]/, fn -> Typsty.format("x", indnet: 2) end

      assert_raise ArgumentError, ~r/^invalid value for :line_length option: expected positive integer/, fn ->
        Typsty.format("x", line_length: 0)
      end

      assert_raise ArgumentError, ~r/^unknown options \[:ppi\], valid options are: \[:font_paths/, fn ->
        Typsty.font_families(ppi: 1)
      end
    end
  end

  describe "to_pdf!/3" do
    test "returns the PDF" do
      assert "%PDF-" <> _ = Typsty.to_pdf!("Hello")
    end

    test "raises a RenderError with the diagnostics" do
      error = assert_raise RenderError, fn -> Typsty.to_pdf!("Hello #nobody") end
      assert Exception.message(error) =~ "1:8: unknown variable: nobody"
    end
  end

  describe "to_png/3" do
    test "renders each page as a PNG" do
      assert {:ok, [<<137, "PNG", _::binary>>, <<137, "PNG", _::binary>>]} = Typsty.to_png("One #pagebreak() Two")
    end

    test "renders at the given resolution" do
      source = "#set page(width: 1in, height: 1in, margin: 0pt)"
      assert {:ok, [png]} = Typsty.to_png(source, %{}, ppi: 72)
      assert png_size(png) == {72, 72}

      assert [png] = Typsty.to_png!(source, %{}, ppi: 300)
      assert png_size(png) == {300, 300}
    end
  end

  describe "to_svg/3" do
    test "renders each page as an SVG" do
      assert {:ok, ["<svg" <> _, "<svg" <> _]} = Typsty.to_svg("One #pagebreak() Two")
      assert ["<svg" <> _] = Typsty.to_svg!("One")
    end
  end

  describe "files" do
    test "reads files from the :files option" do
      source = ~S"""
      #image("logo.png", width: 1cm)
      #image("/images/logo.png", width: 1cm)
      #let data = json("data.json")
      #assert.eq(data.count, 3)
      """

      files = %{"logo.png" => @png, "images/logo.png" => @png, "data.json" => ~s({"count": 3})}
      assert {:ok, _pdf} = Typsty.to_pdf(source, %{}, files: files)
      assert {:ok, _pdf} = Typsty.to_pdf(source, %{}, files: Enum.to_list(files))
    end

    test "imports Typst files from the :files option" do
      files = %{"lib/helpers.typ" => "#let double(x) = x * 2", "lib/more.typ" => ~S(#import "helpers.typ": double)}

      source = ~S"""
      #import "lib/more.typ": double
      #assert.eq(double(2), 4)
      """

      assert {:ok, _pdf} = Typsty.to_pdf(source, %{}, files: files)
    end

    test "reads files from the :root directory, after the :files option" do
      root = tmp_dir!("root")
      File.write!(Path.join(root, "a.txt"), "from disk")
      File.write!(Path.join(root, "b.txt"), "from disk")

      source = ~S"""
      #assert.eq(read("a.txt"), "from disk")
      #assert.eq(read("b.txt"), "from files")
      """

      assert {:ok, _pdf} = Typsty.to_pdf(source, %{}, root: root, files: %{"b.txt" => "from files"})
    end

    test "returns an error for a file that wasn't given, without reading from disk" do
      assert {:error, %RenderError{diagnostics: [diagnostic]}} = Typsty.to_pdf(~S|#read("mix.exs")|)
      assert diagnostic.message =~ "/mix.exs is not in the :files option"
    end

    test "points errors in other files at those files" do
      files = %{"broken.typ" => "#let f() = {\n  nobody\n}"}

      assert {:error, %RenderError{diagnostics: [diagnostic]}} =
               Typsty.to_pdf(~s|#import "broken.typ": f\n#f()|, %{}, files: files)

      assert %Diagnostic{message: "unknown variable: nobody", file: "/broken.typ", line: 2, column: 3} = diagnostic
      assert [%{message: "while calling `f`", file: nil, line: 2, column: 2}] = diagnostic.trace

      assert Exception.message(%RenderError{diagnostics: [diagnostic]}) =~
               "/broken.typ:2:3: unknown variable: nobody\n  2:2: while calling `f`"
    end

    test "reserves the template's own path" do
      assert_raise ArgumentError, ~r/reserved/, fn -> Typsty.to_pdf("x", %{}, files: %{"main.typ" => "y"}) end
    end

    test "raises for invalid files" do
      assert_raise ArgumentError,
                   ~r/^invalid value for :files option: expected paths \(strings\) mapped to binaries/,
                   fn ->
                     Typsty.to_pdf("x", %{}, files: %{logo: "y"})
                   end

      assert_raise ArgumentError, ~r/invalid file path/, fn -> Typsty.to_pdf("x", %{}, files: %{"../up.txt" => "y"}) end
    end
  end

  describe "packages" do
    test "imports packages from the :package_paths directories" do
      packages = tmp_dir!("packages")
      package = Path.join(packages, "local/greet/0.1.0")
      File.mkdir_p!(package)

      File.write!(Path.join(package, "typst.toml"), """
      [package]
      name = "greet"
      version = "0.1.0"
      entrypoint = "lib.typ"
      """)

      File.write!(Path.join(package, "lib.typ"), ~S|#let greet(name) = "Hello " + name|)

      source = ~S"""
      #import "@local/greet:0.1.0": greet
      #assert.eq(greet(assigns.name), "Hello World")
      """

      assert {:ok, _pdf} = Typsty.to_pdf(source, %{name: "World"}, package_paths: [packages])

      assert {:error, %RenderError{diagnostics: [diagnostic]}} = Typsty.to_pdf(source, %{name: "World"})
      assert diagnostic.message =~ "@local/greet:0.1.0"
    end
  end

  describe "validate/1" do
    test "returns :ok for valid syntax, even with unknown variables" do
      assert :ok = Typsty.validate("= Hello #name")
    end

    test "returns the syntax errors" do
      assert {:error, [%Diagnostic{message: "unclosed delimiter", line: 2, column: 10}]} =
               Typsty.validate("Fine\n#let x = (1, 2")
    end
  end

  describe "format/2" do
    test "formats with typstyle" do
      assert {:ok, "#let x = (1, 2)\n= Title\n"} = Typsty.format("#let   x=(1,2)\n= Title")
    end

    test "uses the options" do
      source = "#let items = (\"first item\", \"second item\", \"third item\")"
      assert {:ok, formatted} = Typsty.format(source, line_length: 30, indent: 4)
      assert formatted == "#let items = (\n    \"first item\",\n    \"second item\",\n    \"third item\",\n)\n"
    end

    test "returns the syntax errors for invalid syntax" do
      assert {:error, [%Diagnostic{message: "unclosed delimiter"}]} = Typsty.format("#let x = (1, 2")
    end
  end

  describe "font_families/1" do
    test "lists the embedded fonts" do
      assert Typsty.font_families(system_fonts: false) == [
               "DejaVu Sans Mono",
               "Libertinus Serif",
               "New Computer Modern",
               "New Computer Modern Math"
             ]
    end
  end

  defp png_size(<<137, "PNG", _::binary-size(12), width::32, height::32, _::binary>>), do: {width, height}

  defp tmp_dir!(name) do
    dir = Path.join([System.tmp_dir!(), "typsty_test", "#{name}_#{System.unique_integer([:positive])}"])
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end
