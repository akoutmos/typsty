defmodule Typsty.PDFTest do
  # What the PDFs Typsty renders hold: their pages, metadata, outline, links, fonts and
  # images, read from the PDF's structure
  use ExUnit.Case, async: true

  alias Typsty.RenderError
  alias Typsty.Test.PDF

  import Typsty.Test.Helpers, only: [png_size: 1]

  describe "pages" do
    test "there's a page for each page break, as there's a PNG and an SVG for each" do
      source = ~S|#for i in range(assigns.pages) { if i > 0 { pagebreak() }; [Page #(i + 1)] }|

      for pages <- [1, 3, 25] do
        assert {:ok, pdf} = Typsty.to_pdf(source, %{pages: pages})
        assert PDF.page_count(pdf) == pages
        assert {:ok, pngs} = Typsty.to_png(source, %{pages: pages}, ppi: 10)
        assert length(pngs) == pages
        assert {:ok, svgs} = Typsty.to_svg(source, %{pages: pages})
        assert length(svgs) == pages
      end
    end

    test "content too long for a page continues on the next ones" do
      source =
        ~S|#table(columns: 2, table.header[*Item*][*Price*], ..assigns.items.map(item => (item.name, str(item.price))).flatten())|

      items = for i <- 1..200, do: %{name: "Item #{i}", price: i}

      assert {:ok, pdf} = Typsty.to_pdf(source, %{items: items})
      pages = PDF.page_count(pdf)
      assert pages > 3
      assert {:ok, pngs} = Typsty.to_png(source, %{items: items}, ppi: 10)
      assert length(pngs) == pages

      # Fewer rows take fewer pages
      assert {:ok, short} = Typsty.to_pdf(source, %{items: Enum.take(items, 20)})
      assert PDF.page_count(short) == 1
    end

    test "an empty template is one empty page" do
      assert {:ok, pdf} = Typsty.to_pdf("")
      assert PDF.page_count(pdf) == 1
      assert PDF.fonts(pdf) == []
    end

    test "have the size the template sets, page by page" do
      source = """
      #set page(paper: "a4")
      A4
      #set page(paper: "us-letter", flipped: true)
      Letter, flipped
      #set page(width: 10cm, height: 5cm, flipped: false)
      Custom
      """

      assert {:ok, pdf} = Typsty.to_pdf(source)

      assert [[+0.0, +0.0, a4_width, a4_height], [+0.0, +0.0, 792.0, 612.0], [+0.0, +0.0, width, height]] =
               PDF.media_boxes(pdf)

      assert_in_delta a4_width, 595.28, 0.01
      assert_in_delta a4_height, 841.89, 0.01
      assert_in_delta width, 283.46, 0.01
      assert_in_delta height, 141.73, 0.01

      # PNGs and SVGs have the same sizes
      assert {:ok, [a4_png, letter_png, custom_png]} = Typsty.to_png(source, %{}, ppi: 72)
      assert Enum.map([a4_png, letter_png, custom_png], &png_size/1) == [{595, 842}, {792, 612}, {283, 142}]

      assert {:ok, [a4_svg | _]} = Typsty.to_svg(source)
      assert a4_svg =~ ~r/<svg viewBox="0 0 595\.27\d* 841\.88\d*" width="595\.27\d*pt" height="841\.88\d*pt"/
    end
  end

  describe "metadata" do
    test "has the title, authors and keywords the template sets, from the assigns" do
      source =
        "#set document(title: assigns.title, author: assigns.authors, keywords: assigns.keywords, date: none)\nHi"

      assigns = %{
        title: ~S|Q3 (draft) \ report <for> "you" & é 日本|,
        authors: ["O'Neil", "Zoë"],
        keywords: ["finance", "q3 2026"]
      }

      assert {:ok, pdf} = Typsty.to_pdf(source, assigns)

      assert PDF.info(pdf) == %{
               "Title" => assigns.title,
               "Author" => "O'Neil, Zoë",
               "Keywords" => "finance, q3 2026",
               "Creator" => "Typst #{Typsty.typst_version()}"
             }

      # The XMP metadata escapes what XML needs escaped
      assert PDF.xmp(pdf, "dc:title") == ~S|Q3 (draft) \ report &lt;for&gt; &quot;you&quot; &amp; é 日本|
    end

    test "is dated when it's rendered, unless the template gives a date" do
      before = DateTime.utc_now() |> DateTime.truncate(:second)
      assert {:ok, pdf} = Typsty.to_pdf("Hi")
      after_render = DateTime.utc_now()

      assert {:ok, created, 0} = DateTime.from_iso8601(PDF.xmp(pdf, "xmp:CreateDate"))
      assert DateTime.compare(created, before) != :lt
      assert DateTime.compare(created, after_render) != :gt

      source = "#set document(date: assigns.date)\nHi"

      for {date, expected} <- [
            {~N[2026-03-04 05:06:07], "2026-03-04T05:06:07Z"},
            {~U[2026-03-04 05:06:07.123Z], "2026-03-04T05:06:07Z"},
            {~D[2026-03-04], "2026-03-04T00:00:00Z"}
          ] do
        assert {:ok, pdf} = Typsty.to_pdf(source, %{date: date})
        assert PDF.xmp(pdf, "xmp:CreateDate") == expected
        assert PDF.info(pdf)["CreationDate"] == "D:" <> String.replace(expected, ~r/[-:T]/, "")
      end
    end

    test "without a date, is the same every time it's rendered" do
      undated = "#set document(date: none)\nHello"
      assert {:ok, undated_pdf} = Typsty.to_pdf(undated)
      refute undated_pdf =~ "CreationDate"
      refute undated_pdf =~ "xmp:CreateDate"
      assert Typsty.to_pdf(undated) == {:ok, undated_pdf}

      # PDFs from different times differ in their dates, and in nothing else but their ID,
      # which is a hash of their content
      dated = "#set document(date: assigns.date)\nHello"
      assert {:ok, first} = Typsty.to_pdf(dated, %{date: ~U[2026-03-04 05:06:07Z]})
      assert {:ok, second} = Typsty.to_pdf(dated, %{date: ~U[2026-03-04 05:06:08Z]})
      assert first != second
      assert without_dates(first) == without_dates(second)
    end
  end

  describe "outline" do
    test "has the template's headings, nested by level, with their numbering" do
      source = """
      #set heading(numbering: "1.1")
      = Introduction
      == Scope
      == Café
      = Results
      #heading(level: 2, outlined: false)[Not in the outline]
      === Deep
      = Appendix
      """

      assert {:ok, pdf} = Typsty.to_pdf(source)

      # A heading that isn't in the outline still counts in the numbering, and the headings
      # under it go under the one above it
      assert PDF.outline(pdf) == [
               {"1 Introduction", [{"1.1 Scope", []}, {"1.2 Café", []}]},
               {"2 Results", [{"2.1.1 Deep", []}]},
               {"3 Appendix", []}
             ]
    end

    test "is left out of documents without headings" do
      assert {:ok, pdf} = Typsty.to_pdf("No headings here")
      assert PDF.outline(pdf) == []
    end
  end

  describe "links" do
    test "keep web, mail, phone and relative URLs, in order, and drop others" do
      urls = [
        "https://example.com/a?b=1&c=(2)",
        "javascript:alert(1)",
        "http://example.org",
        "data:text/html,<script>alert(1)</script>",
        "mailto:billing@example.com",
        "file:///etc/passwd",
        "tel:+15555550100",
        "VBScript:msgbox(1)",
        "invoices/42.pdf"
      ]

      assert {:ok, pdf} = Typsty.to_pdf(~S|#for url in assigns.urls [#link(url)[x] ]|, %{urls: urls})

      assert PDF.link_uris(pdf) == [
               "https://example.com/a?b=1&c=(2)",
               "http://example.org",
               "mailto:billing@example.com",
               "tel:+15555550100",
               "invoices/42.pdf"
             ]
    end

    test "to places in the document aren't URLs" do
      assert {:ok, pdf} = Typsty.to_pdf("#link(<total>)[See the total]\n#pagebreak()\n= Total <total>")
      assert PDF.link_uris(pdf) == []
      assert pdf =~ "/Subtype/Link"
    end
  end

  describe "fonts" do
    test "without system fonts, are the embedded ones, subset for what's used" do
      source = "Regular *bold* _italic_ $x^2 + y$ `code`"
      assert {:ok, pdf} = Typsty.to_pdf(source, %{}, system_fonts: false)

      assert PDF.fonts(pdf) == [
               "DejaVuSansMono",
               "LibertinusSerif-Bold",
               "LibertinusSerif-Italic",
               "LibertinusSerif-Regular",
               "NewCMMath-Book"
             ]

      assert {:ok, plain} = Typsty.to_pdf("Regular", %{}, system_fonts: false)
      assert PDF.fonts(plain) == ["LibertinusSerif-Regular"]
    end
  end

  describe "images" do
    test "from :files are embedded at their size in pixels" do
      {:ok, [png]} = Typsty.to_png("#set page(width: 10pt, height: 5pt, margin: 0pt, fill: red)", %{}, ppi: 72)
      assert png_size(png) == {10, 5}

      {:ok, [large]} = Typsty.to_png("#set page(width: 30pt, height: 20pt, margin: 0pt, fill: blue)", %{}, ppi: 72)

      source = ~S|#image("pixel.png", width: 2cm) #image("pixel.png", width: 4cm) #image("large.png")|
      assert {:ok, pdf} = Typsty.to_pdf(source, %{}, files: %{"pixel.png" => png, "large.png" => large})

      # An image is embedded once, however many times it's shown
      assert Enum.sort(PDF.images(pdf)) == [{10, 5}, {30, 20}]
    end

    test "that aren't images are an error, pointing at the line that reads them" do
      source = ~s|Logo:\n#image("logo.png")|

      assert {:error, %RenderError{diagnostics: [diagnostic]}} =
               Typsty.to_pdf(source, %{}, files: %{"logo.png" => "not a png"})

      assert diagnostic.line == 2
      assert diagnostic.message =~ "failed to decode image"
    end
  end

  describe "PDF standards" do
    test "are declared in the PDF, with the version they need" do
      titled = "#set document(title: [Report])\n#set text(lang: \"en\")\nHello"

      assert {:ok, default} = Typsty.to_pdf(titled)
      assert PDF.version(default) == "1.7"
      assert PDF.xmp(default, "pdfaid:part") == nil

      assert {:ok, pdf_a} = Typsty.to_pdf(titled, %{}, pdf_standards: ["a-2b"])
      assert {PDF.xmp(pdf_a, "pdfaid:part"), PDF.xmp(pdf_a, "pdfaid:conformance")} == {"2", "B"}
      assert pdf_a =~ "/Type/OutputIntent"

      assert {:ok, pdf_ua} = Typsty.to_pdf(titled, %{}, pdf_standards: ["ua-1"])
      assert PDF.xmp(pdf_ua, "pdfuaid:part") == "1"

      assert {:ok, both} = Typsty.to_pdf(titled, %{}, pdf_standards: ["a-2a", "ua-1"])
      assert {PDF.xmp(both, "pdfaid:conformance"), PDF.xmp(both, "pdfuaid:part")} == {"A", "1"}

      assert {:ok, pdf_2} = Typsty.to_pdf(titled, %{}, pdf_standards: ["2.0"])
      assert PDF.version(pdf_2) == "2.0"
    end

    test "that a document doesn't meet are errors" do
      assert {:error, %RenderError{reason: :typst, diagnostics: [%{message: "PDF/UA-1 error: missing document title"}]}} =
               Typsty.to_pdf("Hello", %{}, pdf_standards: ["ua-1"])
    end
  end

  # The PDF with its dates (in its info dictionary and its XMP metadata) and its ID (in its
  # trailer and its XMP metadata) blanked out
  defp without_dates(pdf) do
    pdf
    |> String.replace(~r/D:\d{14}Z|\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ/, "DATE")
    |> String.replace(~r"<xmpMM:(InstanceID|DocumentID)>[^<]*<", "<xmpMM:\\1>ID<")
    |> String.replace(~r"/ID\[[^\]]*\]", "/ID[]")
  end
end
