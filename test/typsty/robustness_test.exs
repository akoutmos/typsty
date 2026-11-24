defmodule Typsty.RobustnessTest do
  # Inputs that used to crash the VM (a stack overflow or a failed allocation in the NIF) or
  # hang a scheduler, and now return errors. If any of these regress, the test run dies.
  use ExUnit.Case, async: true

  alias Typsty.RenderError

  defp nest_list(0, acc), do: acc
  defp nest_list(n, acc), do: nest_list(n - 1, [acc])

  defp assert_render_error(result, message) do
    assert {:error, %RenderError{diagnostics: diagnostics}} = result
    assert Enum.any?(diagnostics, &(&1.message =~ message)), inspect(diagnostics)
  end

  describe "deeply nested data" do
    test "is refused before it reaches Typst" do
      error = assert_raise ArgumentError, fn -> Typsty.to_pdf("#v", %{v: nest_list(10_000, 1)}) end
      assert error.message =~ "assigns.v[0][0][0][0][0]…[0][0][0][0] is nested too deeply"

      assert {:ok, _pdf} = Typsty.to_pdf("#assigns.v.len()", %{v: nest_list(200, 1)})
    end
  end

  describe "deep recursion in Typst" do
    test "deeply nested content built by a loop" do
      result = Typsty.to_pdf("#let c = [x]\n#for i in range(20000) { c = box(c) }\n#c")
      assert_render_error(result, "maximum layout depth exceeded")
    end

    test "comparing deeply nested values" do
      source = "#let a = (:)\n#let b = (:)\n#for i in range(50000) { a = (k: a); b = (k: b) }\n#assert(a == b)"
      assert {:ok, _pdf} = Typsty.to_pdf(source)
    end
  end

  describe "panics in Typst" do
    test "are returned as errors" do
      result = Typsty.to_pdf("#datetime.today(offset: 9223372036854775807)")
      assert_render_error(result, "Typst crashed")

      assert {:ok, _pdf} = Typsty.to_pdf("still works")
    end
  end

  describe "PNG export" do
    test "refuses pages that would need too much memory" do
      assert_render_error(Typsty.to_png("x", %{}, ppi: 1_000_000), "page 1 can't be rendered as a PNG")
      assert_render_error(Typsty.to_png("#set page(width: 100000cm, height: 100000cm)\nx"), "the page needs")
    end

    test "refuses images, gradients and tilings far larger than the page" do
      svg = ~s(<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10"/></svg>)
      image = "#set page(width: 2cm, height: 2cm)\n#image(\"i.svg\", width: 1000000cm)"
      assert_render_error(Typsty.to_png(image, %{}, files: %{"i.svg" => svg}), "an image needs")

      gradient =
        "#set page(width: 2cm, height: 2cm)\n#place(rect(width: 1000000cm, height: 1000000cm, fill: gradient.linear(red, blue)))"

      assert_render_error(Typsty.to_png(gradient), "a gradient needs")

      tiling = "#set page(width: 2cm, height: 2cm)\n#rect(fill: tiling(size: (100000cm, 100000cm))[x])"
      assert_render_error(Typsty.to_png(tiling), "a tiling needs")

      # PDF and SVG don't rasterize, so the same documents work
      assert {:ok, _pdf} = Typsty.to_pdf(gradient)
    end

    test "sizes gradients relative to their parent by the nearest block, not the innermost group" do
      # The gradient fills the huge block it's in, through the group `scale` adds
      source =
        "#place(block(width: 8000000cm, height: 8000000cm)[#scale(100%)[" <>
          "#rect(width: 1cm, height: 1cm, fill: gradient.linear(red, blue, relative: \"parent\"))]])"

      assert_render_error(Typsty.to_png(source), "a gradient needs")
    end

    test "still renders ordinary pages with many gradients" do
      boxes = for i <- 1..200, into: "", do: "#box(width: 1cm, height: 1cm, fill: gradient.linear(red, blue)) #{i}\n"
      assert {:ok, [_ | _]} = Typsty.to_png(boxes, %{}, ppi: 300)
    end
  end

  describe "image decompression bombs" do
    # Images whose headers claim 60,000 × 60,000 pixels. Decoding them would allocate
    # gigabytes, and a failed allocation aborts the VM.
    defp png_bomb do
      chunk = fn type, data -> <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>> end
      header = <<60_000::32, 60_000::32, 8, 6, 0, 0, 0>>

      <<137, "PNG\r\n", 26, "\n">> <>
        chunk.("IHDR", header) <> chunk.("IDAT", :zlib.compress(<<0::8000>>)) <> chunk.("IEND", "")
    end

    defp jpeg_bomb,
      do: <<0xFF, 0xD8, 0xFF, 0xC0, 0, 17, 8, 60_000::16, 60_000::16, 3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1>>

    defp gif_bomb, do: "GIF89a" <> <<60_000::little-16, 60_000::little-16, 0, 0, 0, 0x3B>>

    test "are refused before Typst decodes them" do
      for {name, bomb} <- [{"bomb.png", png_bomb()}, {"bomb.jpg", jpeg_bomb()}, {"bomb.gif", gif_bomb()}],
          render <- [&Typsty.to_pdf/3, &Typsty.to_png/3] do
        result = render.("#image(\"#{name}\", width: 2cm)", %{}, files: %{name => bomb})
        assert_render_error(result, "the image is too large to decode: 60000 × 60000 pixels")
      end
    end
  end

  describe "PDF files" do
    test "are refused inside the VM, where a malformed one could crash it" do
      pdf = "%PDF-1.7\n1 0 obj << /Type /Catalog >> endobj\n"

      for {name, contents} <- [{"doc.pdf", pdf}, {"renamed.png", "junk\n" <> pdf}, {"no-header.pdf", "junk"}] do
        result = Typsty.to_pdf("#image(\"#{name}\")", %{}, files: %{name => contents})
        assert_render_error(result, "PDF files can't be used when rendering inside the VM")
      end
    end
  end

  describe "compressed SVGs and XML entities" do
    test "are refused when they expand too much" do
      bomb = :zlib.gzip(:binary.copy(" ", 129 * 1024 * 1024))
      result = Typsty.to_pdf("#image(\"i.svgz\")", %{}, files: %{"i.svgz" => bomb})
      assert_render_error(result, "the compressed file expands to more than 128 MiB")

      laughs = ~s(<!DOCTYPE a [<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;">]><a>&b;&b;</a>)
      result = Typsty.to_pdf(~S|#xml("d.xml")|, %{}, files: %{"d.xml" => laughs})
      assert_render_error(result, "an XML entity that contains markup or refers to other entities")

      # Flat entities, like the ones Adobe Illustrator writes, are fine
      svg =
        ~s(<!DOCTYPE svg [<!ENTITY ns "http://www.w3.org/2000/svg">]>) <>
          ~s(<svg xmlns="&ns;" width="10" height="10"><rect width="10" height="10"/></svg>)

      assert {:ok, _pdf} = Typsty.to_pdf(~S|#image("i.svg", width: 1cm)|, %{}, files: %{"i.svg" => svg})
    end

    test "data files that only look like images or XML aren't refused" do
      files = %{
        # imagesize takes "BM" for a bitmap's header
        "cars.csv" => "BMW,1\nAudi,2\n",
        "page.html" => "<html><body>" <> String.duplicate("line<br>", 2000) <> "</body></html>"
      }

      assert {:ok, _pdf} = Typsty.to_pdf(~S|#csv("cars.csv").len() #read("page.html").len()|, %{}, files: files)
    end
  end

  describe "file paths" do
    test "a render that reads too many different files is stopped" do
      # Errors in context blocks don't stop Typst, so this would go on to use up Typst's
      # table of file paths, which lasts for the life of the VM
      source = "#for i in range(10001) { context read(\"many/\" + str(i)) }"
      assert_render_error(Typsty.to_pdf(source), "the document reads more than 10000 different files")

      assert {:ok, _pdf} = Typsty.to_pdf("still works")
    end
  end

  describe "deeply nested SVG and XML" do
    test "are refused before Typst parses them" do
      svg =
        ~s(<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">) <>
          String.duplicate("<g>", 5000) <> String.duplicate("</g>", 5000) <> "</svg>"

      result = Typsty.to_pdf("#image(\"i.svg\", width: 2cm)", %{}, files: %{"i.svg" => svg})
      assert_render_error(result, "nested more than 1024 levels deep")

      xml = String.duplicate("<a>", 5000) <> String.duplicate("</a>", 5000)

      assert_render_error(
        Typsty.to_pdf(~S|#xml("d.xml")|, %{}, files: %{"d.xml" => xml}),
        "nested more than 1024 levels deep"
      )
    end
  end

  describe "reading from the root directory" do
    @describetag :tmp_dir

    @tag :unix
    test "refuses devices and FIFOs, which would never finish reading", %{tmp_dir: dir} do
      {_, 0} = System.cmd("mkfifo", [Path.join(dir, "pipe.txt")])
      assert_render_error(Typsty.to_pdf(~S|#read("pipe.txt")|, %{}, root: dir), "is not a regular file")
    end

    @tag :unix
    test "refuses symbolic links that lead outside the root", %{tmp_dir: dir} do
      root = Path.join(dir, "root")
      File.mkdir_p!(Path.join(root, "assets"))
      File.write!(Path.join(dir, "secret.txt"), "secret")
      File.write!(Path.join(root, "assets/inside.txt"), "inside")

      File.ln_s!(Path.join(dir, "secret.txt"), Path.join(root, "secret.txt"))
      File.ln_s!("/dev/zero", Path.join(root, "zero.txt"))
      File.ln_s!(Path.join(root, "assets"), Path.join(root, "linked"))

      for name <- ["secret.txt", "zero.txt"] do
        result = Typsty.to_pdf(~s|#read("#{name}")|, %{}, root: root)
        assert_render_error(result, "/#{name} is outside the :root directory, through a symbolic link")
      end

      # Links that stay inside the root are fine
      assert {:ok, _pdf} = Typsty.to_pdf(~S|#assert.eq(read("linked/inside.txt"), "inside")|, %{}, root: root)

      # Files outside the root can't be named either
      File.write!(Path.join(dir, "outside.txt"), "outside")
      result = Typsty.to_pdf(~S|#read("../outside.txt")|, %{}, root: root)
      assert {:error, %RenderError{diagnostics: [%{hints: hints}]}} = result
      assert "files outside the project root can only be read by changing the :root option" in hints
    end
  end

  describe "timeouts" do
    test "return an error while the render finishes in the background" do
      slow = "#let n = 0\n#for i in range(20000000) { n += 1 }\n#n"
      assert_render_error(Typsty.to_pdf(slow, %{}, timeout: 50), "didn't finish within the timeout (50 ms)")
      assert {:ok, _pdf} = Typsty.to_pdf("still works", %{}, timeout: :infinity)

      assert_raise ArgumentError, ~r/:timeout option must be a positive integer/, fn ->
        Typsty.to_pdf("x", %{}, timeout: 0)
      end
    end
  end
end
