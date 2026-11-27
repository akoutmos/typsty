defmodule Typsty.ComponentFilesTest do
  # Components' own files: images, data and .typ files in a folder next to the component,
  # which renders get at components/<name>/
  use ExUnit.Case, async: true

  alias Typsty.{RenderError, SyntaxError}
  alias Typsty.Test.{Brand, Icons, LabelA, LabelB, PDF, Stamp}

  import Typsty.Test.Helpers, only: [compile!: 3, position: 2, unload: 1]

  @no_date "#set document(date: none)\n"
  @stamp_dir "test/support/components/stamp"

  describe "a component's files" do
    test "are its folder's files, by their path in it, but hidden ones" do
      assert Stamp.__typsty_files__() |> Enum.map(&elem(&1, 0)) ==
               ["caption.txt", "data/codes.json", "helpers.typ", "pixel.png", "seal.svg"]

      assert {"pixel.png", File.read!(Path.join(@stamp_dir, "pixel.png"))} in Stamp.__typsty_files__()
      assert Icons.__typsty_files__() |> Enum.map(&elem(&1, 0)) == ["check.svg", "cross.svg"]
      assert Brand.__typsty_files__() == []
    end

    test "are read by the component by their path in components/" do
      source = """
      #import "components/stamp.typ": stamp, codes, pixel
      #assert.eq(codes, assigns.codes)
      #stamp[Paid] #pixel(1cm)
      """

      codes = @stamp_dir |> Path.join("data/codes.json") |> File.read!() |> JSON.decode!()
      assert {:ok, pdf} = Typsty.to_pdf(source, %{codes: codes}, components: [Stamp])

      # The PNG is embedded as an image, at its size; the SVG is drawn
      assert PDF.images(pdf) == [{2, 2}]
    end

    test "render what the same files given with :files render" do
      body = "#stamp[Paid]\n#pixel(2cm)\n#codes.len() codes"
      imported = @no_date <> ~s|#import "components/stamp.typ": stamp, pixel, codes\n| <> body

      # The component's code, reading the same files from elsewhere
      inline =
        @no_date <>
          """
          #let caption = read("assets/caption.txt").trim()
          #let framed(body) = rect(inset: 4pt)[#body #emph(caption)]
          #let seal(size: 1cm) = image("assets/seal.svg", width: size)
          #let codes = json("assets/data/codes.json")
          #let stamp(body) = framed[#seal() #body]
          #let pixel(width) = image("/assets/pixel.png", width: width)
          """ <> body

      files =
        for name <- ["caption.txt", "seal.svg", "data/codes.json", "pixel.png"],
            into: %{},
            do: {"assets/#{name}", File.read!(Path.join(@stamp_dir, name))}

      for render <- [&Typsty.to_pdf/3, &Typsty.to_png/3, &Typsty.to_svg/3] do
        assert {:ok, _output} = expected = render.(inline, %{}, files: files)
        assert render.(imported, %{}, components: [Stamp]) == expected
      end
    end

    test "can be read by documents too" do
      source = ~s|#image("components/stamp/seal.svg")\n#assert.eq(read("components/stamp/caption.txt"), "Approved\\n")|
      assert {:ok, _svg} = Typsty.to_svg(source, %{}, components: [Stamp])
    end

    test "are served at the component's name, from the folder it was given" do
      source = ~s|#import "components/icon-set.typ": check, icon\n#check() #icon("cross")|
      assert {:ok, _svg} = Typsty.to_svg(source, %{}, components: [Icons])

      # A path built at runtime is only known to be missing when the document renders
      assert {:error, %RenderError{diagnostics: [diagnostic]}} =
               Typsty.to_svg(~s|#import "components/icon-set.typ": icon\n#icon("nope")|, %{}, components: [Icons])

      assert diagnostic.message =~
               "/components/icon-set/nope.svg is not one of the render's components, or one of their files"

      icons = "test/support/components/icons.ex"
      assert {diagnostic.file, diagnostic.line} == {icons, elem(position(icons, "#let icon(name)"), 0)}
    end

    test "aren't served when they're hidden, or the component isn't given" do
      assert {:error, %RenderError{diagnostics: [%{message: message}]}} =
               Typsty.to_svg(~s|#read("components/stamp/.hidden")|, %{}, components: [Stamp])

      assert message =~ "/components/stamp/.hidden is not one of the render's components, or one of their files"

      assert {:error, %RenderError{}} = Typsty.to_svg(~s|#read("components/stamp/caption.txt")|)
    end

    test "can't be replaced by :files, or read from :root", %{} do
      assert_raise ArgumentError, ~r/the path "components\/stamp\/seal.svg" is in components\//, fn ->
        Typsty.to_svg("x", %{}, components: [Stamp], files: %{"components/stamp/seal.svg" => "<svg/>"})
      end

      root = Path.join(System.tmp_dir!(), "typsty-root-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "components/stamp"))
      on_exit(fn -> File.rm_rf!(root) end)
      File.write!(Path.join(root, "components/stamp/caption.txt"), "Forged")

      source = ~s|#import "components/stamp.typ": stamp\n#stamp[Paid]|

      assert {:ok, _svgs} = expected = Typsty.to_svg(source, %{}, components: [Stamp])
      assert Typsty.to_svg(source, %{}, components: [Stamp], root: root) == expected

      # The forged caption would change the output
      forged = ~s|#rect(inset: 4pt)[#image("components/stamp/seal.svg", width: 1cm) Paid #emph[Forged]]|
      assert {:ok, _svgs} = forged_output = Typsty.to_svg(forged, %{}, components: [Stamp])
      assert forged_output != expected
    end

    test "of components with the same name aren't mixed up by renders at the same time" do
      source = ~s|#import "components/label.typ": label\n#text(size: 40pt, label)|

      expected = %{
        LabelA => Typsty.to_svg(source, %{}, components: [LabelA]),
        LabelB => Typsty.to_svg(source, %{}, components: [LabelB])
      }

      assert {:ok, _svgs} = expected[LabelA]
      assert {:ok, _svgs} = expected[LabelB]
      assert expected[LabelA] != expected[LabelB]

      1..40
      |> Task.async_stream(
        fn i ->
          label = if rem(i, 2) == 0, do: LabelA, else: LabelB
          {label, Typsty.to_svg(source, %{}, components: [label])}
        end,
        timeout: :infinity
      )
      |> Enum.each(fn {:ok, {label, result}} -> assert result == expected[label] end)
    end

    test "render the same in a Typsty.Pool" do
      start_supervised!({Typsty.Pool, name: __MODULE__.Pool, size: 1})
      source = @no_date <> ~s|#import "components/stamp.typ": stamp, pixel\n#stamp[Paid] #pixel(1cm)|

      assert {:ok, "%PDF-" <> _} = expected = Typsty.to_pdf(source, %{}, components: [Stamp])
      assert Typsty.to_pdf(source, %{}, components: [Stamp], pool: __MODULE__.Pool) == expected
    end
  end

  describe ".typ files in a component's folder" do
    test "are checked like components, and their errors point at them" do
      source = ~s|#import "components/stamp/helpers.typ": broken\n#broken()|
      assert {:error, %RenderError{diagnostics: [diagnostic]}} = Typsty.to_svg(source, %{}, components: [Stamp])

      assert diagnostic.message =~ "cannot add"
      # At the addition
      helpers = "#{@stamp_dir}/helpers.typ"

      assert {diagnostic.file, diagnostic.line, diagnostic.column} ==
               Tuple.insert_at(position(helpers, ~s|"a" + 1|), 0, helpers)

      assert [%{file: nil, line: 2}] = diagnostic.trace
    end
  end

  describe "compiling a component with files" do
    @describetag :tmp_dir

    test "checks the paths it reads its files from, when they're written out", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "seals"))
      File.write!(Path.join(dir, "seals/round.svg"), "<svg/>")

      error =
        assert_raise SyntaxError, fn ->
          compile!(dir, "seals.ex", """
          defmodule Typsty.Test.Seals do
            use Typsty.Component

            def render do
              ~TYPST\"\"\"
              #let round = image("seals/round.svg")
              #let square = image("seals/square.svg")
              #let elsewhere = image("/logo.png") + image("brand/logo.png") + image("../../../outside.png")
              #let built(name) = image("seals/" + name)
              #let around = image("seals/../seals/./round.svg") + image("/components/seals/oval.svg")
              \"\"\"
            end
          end
          """)
        end

      # Only the written-out paths into its own folder that have no file are refused
      assert error.kind == :component

      assert [
               %{line: 7, column: 25, message: "seals/square.svg isn't one of the component's files", hints: [hint]},
               %{line: 10, column: 63, message: "/components/seals/oval.svg isn't one of the component's files"}
             ] = error.diagnostics

      assert hint =~
               "the component's files are in #{Path.relative_to_cwd(Path.join(dir, "seals"))}, which has no square.svg"
    end

    test "refuses paths written as if they were relative to its folder", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "notary"))
      File.write!(Path.join(dir, "notary/seal.svg"), "<svg/>")

      component = """
      defmodule Typsty.Test.Notary do
        use Typsty.Component
        def render, do: ~TYPST|#let seal = image("FILE")|
      end
      """

      for {file, hint} <- [
            {"seal.svg",
             "paths in a component are relative to components/, where it is: its file seal.svg is notary/seal.svg"},
            {"stamp.svg", "paths in a component are relative to components/, where it is: its own files are in notary/"}
          ] do
        error = assert_raise SyntaxError, fn -> compile!(dir, "notary.ex", String.replace(component, "FILE", file)) end
        assert [%{message: message, hints: [^hint]}] = error.diagnostics
        assert message == "#{file} isn't one of the component's files"
      end

      # Other components' sources are there
      compile!(dir, "notary.ex", String.replace(component, ~s|image("FILE")|, ~s|read("brand.typ")|))
    end

    test "refuses paths to its files by its folder's name, when it has another", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "masthead"))
      File.write!(Path.join(dir, "masthead/seal.svg"), "<svg/>")

      error =
        assert_raise SyntaxError, fn ->
          compile!(dir, "masthead.ex", """
          defmodule Typsty.Test.Masthead do
            use Typsty.Component, name: "header"
            def render, do: ~TYPST|#let seal = image("masthead/seal.svg")|
          end
          """)
        end

      assert [%{message: "masthead/seal.svg isn't one of the component's files", hints: [hint]}] = error.diagnostics
      assert hint == "the component reads its files by its name, header, not its folder's: seal.svg is header/seal.svg"

      # By its name, they're there; and another component's folder isn't checked
      compile!(dir, "masthead.ex", """
      defmodule Typsty.Test.Masthead do
        use Typsty.Component, name: "header"
        def render, do: ~TYPST|#let seal = image("header/seal.svg") + image("brand/logo.svg")|
      end
      """)
    end

    test "checks the files it imports from its folder", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "ledger"))
      File.write!(Path.join(dir, "ledger/rows.typ"), "#let row = 1\n")

      [{module, _binary}] =
        compile!(dir, "ledger.ex", """
        defmodule Typsty.Test.Ledger do
          use Typsty.Component
          def render, do: ~TYPST|#import "ledger/rows.typ": row|
        end
        """)

      assert [{"rows.typ", %Typsty.Template{}}] = module.__typsty_files__()
      unload(module)

      error =
        assert_raise SyntaxError, fn ->
          compile!(dir, "ledger.ex", """
          defmodule Typsty.Test.Ledger do
            use Typsty.Component
            def render, do: ~TYPST|#import "ledger/columns.typ": column|
          end
          """)
        end

      assert [%{message: "ledger/columns.typ isn't one of the component's files"}] = error.diagnostics
    end

    test "works wherever the project is, whatever its folders' names", %{tmp_dir: dir} do
      project = Path.join(dir, "we[ir]d {project} *")
      File.mkdir_p!(Path.join(project, "seal/inner"))
      File.write!(Path.join(project, "seal/round.svg"), "<svg/>")
      File.write!(Path.join(project, "seal/inner/square.svg"), "<svg/>")

      [{module, _binary}] =
        compile!(project, "seal.ex", """
        defmodule Typsty.Test.Seal do
          use Typsty.Component
          def render, do: ~TYPST|#let round = image("seal/round.svg")|
        end
        """)

      assert Enum.map(module.__typsty_files__(), &elem(&1, 0)) == ["inner/square.svg", "round.svg"]
      refute module.__mix_recompile__?()
    end

    test "can have its source in its folder, which isn't one of its files", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "rosette"))
      File.write!(Path.join(dir, "rosette/rosette.typ"), ~s|#let rosette = image("rosette/petal.svg")\n|)

      File.write!(
        Path.join(dir, "rosette/petal.svg"),
        ~s|<svg xmlns="http://www.w3.org/2000/svg" width="4" height="4"/>|
      )

      [{module, _binary}] =
        compile!(dir, "rosette.ex", """
        defmodule Typsty.Test.Rosette do
          use Typsty.Component, template: "rosette/rosette.typ"
        end
        """)

      assert Enum.map(module.__typsty_files__(), &elem(&1, 0)) == ["petal.svg"]
      refute module.__mix_recompile__?()

      source = ~s|#import "components/rosette.typ": rosette\n#rosette|
      assert {:ok, _svgs} = Typsty.to_svg(source, %{}, components: [module])
    end

    @tag :unix
    test "refuses files Typst can't read, and follows links in its folder once", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "loopy/nested"))
      File.write!(Path.join(dir, "loopy/nested/a.txt"), "a")
      File.ln_s!(Path.join(dir, "loopy"), Path.join(dir, "loopy/nested/back"))

      component =
        ~s|defmodule Typsty.Test.Loopy do\n  use Typsty.Component\n  def render, do: ~TYPST"#let a = 1"\nend\n|

      [{module, _binary}] = compile!(dir, "loopy.ex", component)
      assert Enum.map(module.__typsty_files__(), &elem(&1, 0)) == ["nested/a.txt"]
      unload(module)

      File.write!(Path.join(dir, "loopy/back\\slash.txt"), "b")

      assert_raise CompileError,
                   ~r/back\\slash.txt, one of the files of Typsty.Test.Loopy, has a backslash in its name/,
                   fn ->
                     compile!(dir, "loopy.ex", component)
                   end
    end

    test "nested in a document module, or next to one, has neither's defaults", %{tmp_dir: dir} do
      # The document's template and folder, which the component nested in it doesn't take
      File.write!(Path.join(dir, "receipt.typ"), ~s|#import "components/total.typ": total\n#total(assigns.amount)|)
      File.mkdir_p!(Path.join(dir, "receipt"))
      File.write!(Path.join(dir, "receipt/logo.svg"), "<svg/>")

      [{receipt, _}, {total, _}] =
        compile!(dir, "receipt.ex", """
        defmodule Typsty.Test.Receipt2.Receipt do
          use Typsty, components: [Typsty.Test.Receipt2.Receipt.Total]

          defmodule Total do
            use Typsty.Component
            def render, do: ~TYPST|#let total(amount) = [Total: #amount]|
          end
        end
        """)
        |> Enum.sort()

      assert total.__typsty_files__() == []
      assert {:ok, _svgs} = Typsty.to_svg(receipt.render(%{amount: 5}), %{}, components: [total])
      assert {:ok, _svgs} = receipt.to_svg(%{amount: 5})

      # A module that isn't named after its file needs a source given
      assert_raise CompileError,
                   ~r/needs a source: .*\(it isn't named after its file, others.ex, so it has none by default\)/,
                   fn ->
                     compile!(dir, "others.ex", "defmodule Typsty.Test.Sibling do\n  use Typsty.Component\nend\n")
                   end

      assert_raise CompileError,
                   ~r/needs a template: .*\(it isn't named after its file, others.ex, so it has none by default\)/,
                   fn ->
                     compile!(dir, "others.ex", "defmodule Typsty.Test.SiblingDocument do\n  use Typsty\nend\n")
                   end
    end

    test "checks the paths of a component without files", %{tmp_dir: dir} do
      component = """
      defmodule Typsty.Test.Plain do
        use Typsty.Component, OPTIONS
        def render, do: ~TYPST|#let logo = image("plain/logo.png")|
      end
      """

      error = assert_raise SyntaxError, fn -> compile!(dir, "plain.ex", String.replace(component, ", OPTIONS", "")) end
      assert [%{message: "plain/logo.png isn't one of the component's files", hints: [hint]}] = error.diagnostics

      assert hint ==
               "the component has no files: they go in #{Path.relative_to_cwd(Path.join(dir, "plain"))}, next to its module"

      error =
        assert_raise SyntaxError, fn ->
          compile!(dir, "plain.ex", String.replace(component, "OPTIONS", "files: false"))
        end

      assert [%{hints: ["the component has no files: it's given `files: false`"]}] = error.diagnostics
    end

    test "takes its files from the folder it's given", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "shared/art"))
      File.write!(Path.join(dir, "shared/art/mark.svg"), "<svg/>")

      [{module, _binary}] =
        compile!(dir, "marked.ex", """
        defmodule Typsty.Test.Marked do
          use Typsty.Component, files: "shared/art"
          def render, do: ~TYPST|#let mark = image("marked/mark.svg")|
        end
        """)

      assert module.__typsty_files__() == [{"mark.svg", "<svg/>"}]
      refute module.__mix_recompile__?()
    end

    test "checks the paths in its .typ files, relative to them", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "badge"))
      File.write!(Path.join(dir, "badge.typ"), ~s|#import "badge/parts.typ": part\n|)
      File.write!(Path.join(dir, "badge/parts.typ"), ~s|#let part = image("ribbon.png")\n|)

      error =
        assert_raise SyntaxError, fn ->
          compile!(dir, "badge.ex", "defmodule Typsty.Test.Badge do\n  use Typsty.Component\nend\n")
        end

      assert {Path.basename(error.file), error.line, error.column} == {"parts.typ", 1, 19}
      assert Exception.message(error) =~ "ribbon.png isn't one of the component's files"
    end

    test "refuses .typ files in its folder that a component couldn't have", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "notice"))
      File.write!(Path.join(dir, "notice/partial.typ"), "#let a = 1\nSome text\n")

      error =
        assert_raise SyntaxError, fn ->
          compile!(dir, "notice.ex", """
          defmodule Typsty.Test.Notice do
            use Typsty.Component
            def render, do: ~TYPST"#let b = 2"
          end
          """)
        end

      assert {error.kind, Path.basename(error.file), error.line} == {:component, "partial.typ", 2}
    end

    test "refuses a folder next to it with Elixir code, which holds modules instead", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "branding"))
      File.write!(Path.join(dir, "branding/colors.ex"), "defmodule Typsty.Test.Branding.Colors do\nend\n")

      component = """
      defmodule Typsty.Test.Branding do
        use Typsty.Component, OPTIONS
        def render, do: ~TYPST"#let b = 2"
      end
      """

      assert_raise CompileError,
                   ~r/branding, the folder for the files of Typsty.Test.Branding, has Elixir code in it \(colors.ex\)/,
                   fn ->
                     compile!(dir, "branding.ex", String.replace(component, ", OPTIONS", ""))
                   end

      [{module, _binary}] = compile!(dir, "branding.ex", String.replace(component, "OPTIONS", "files: false"))
      assert module.__typsty_files__() == []

      # Without a folder, there's nothing to recompile for
      File.write!(Path.join(dir, "branding/logo.png"), "png")
      refute module.__mix_recompile__?()
    end

    test "checks the :files option", %{tmp_dir: dir} do
      assert_raise CompileError, ~r/the :files folder of Typsty.Test.NoFolder, .*nowhere, doesn't exist/, fn ->
        compile!(
          dir,
          "no_folder.ex",
          ~s|defmodule Typsty.Test.NoFolder do\n  use Typsty.Component, files: "nowhere"\n  def render, do: ~TYPST"#let a = 1"\nend\n|
        )
      end

      assert_raise ArgumentError, "the :files option must be a path, or false, got: true", fn ->
        compile!(
          dir,
          "true_folder.ex",
          ~s|defmodule Typsty.Test.TrueFolder do\n  use Typsty.Component, files: true\nend\n|
        )
      end
    end

    test "warns when its files are large, since every render gets them", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "heavy"))
      File.write!(Path.join(dir, "heavy/blob.bin"), :binary.copy(<<0>>, 8 * 1024 * 1024))
      # .typ files count too
      File.write!(Path.join(dir, "heavy/big.typ"), "#let x = 1\n" <> String.duplicate("// padding\n", 95_326))

      warning =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          compile!(
            dir,
            "heavy.ex",
            ~s|defmodule Typsty.Test.Heavy do\n  use Typsty.Component\n  def render, do: ~TYPST"#let a = 1"\nend\n|
          )
        end)

      assert warning =~ "the files of Typsty.Test.Heavy"
      assert warning =~ "take 9.0 MiB, which every render that lists the component is given"
    end

    test "recompiles when files are added to its folder, or taken out", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "growing"))
      File.write!(Path.join(dir, "growing/a.txt"), "a")

      [{module, _binary}] =
        compile!(
          dir,
          "growing.ex",
          ~s|defmodule Typsty.Test.Growing do\n  use Typsty.Component\n  def render, do: ~TYPST"#let a = 1"\nend\n|
        )

      refute module.__mix_recompile__?()

      # Changing a file is noticed through @external_resource; hidden files don't count
      File.write!(Path.join(dir, "growing/a.txt"), "changed")
      File.write!(Path.join(dir, "growing/.DS_Store"), "")
      refute module.__mix_recompile__?()

      File.write!(Path.join(dir, "growing/b.txt"), "b")
      assert module.__mix_recompile__?()

      File.rm!(Path.join(dir, "growing/b.txt"))
      File.rm!(Path.join(dir, "growing/a.txt"))
      assert module.__mix_recompile__?()
    end
  end
end
