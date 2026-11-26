# Two components with the same name and different sources, which renders running at the same
# time must not mix up
defmodule Typsty.ComponentPermutationsTest.BadgeA do
  use Typsty.Component, name: "badge"
  def render, do: ~TYPST|#let badge = "A"|
end

defmodule Typsty.ComponentPermutationsTest.BadgeB do
  use Typsty.Component, name: "badge"
  def render, do: ~TYPST|#let badge = "B"|
end

# A document whose renders get a component by default, by overriding to_svg/2
defmodule Typsty.ComponentPermutationsTest.Branded do
  use Typsty

  def to_svg(assigns, opts),
    do: super(assigns, Keyword.update(opts, :components, [Typsty.Test.Brand], &[Typsty.Test.Brand | &1]))

  def render(assigns) do
    ~TYPST"""
    #import "components/brand.typ": name
    #assert.eq(name, "Acme")
    #name for #assigns.customer
    """
  end
end

defmodule Typsty.ComponentPermutationsTest do
  # Renders of templates with and without components, which must render what the same code
  # does without them, in every format, inside the VM and in a pool
  use ExUnit.Case, async: true

  alias Typsty.ComponentPermutationsTest.{BadgeA, BadgeB, Branded}
  alias Typsty.{Diagnostic, RenderError}

  alias Typsty.Test.{
    AnnualReport,
    Brand,
    Callout,
    Extras,
    Greeting,
    Letterhead,
    Money,
    PDF,
    Report,
    Statement,
    Tables,
    Totals
  }

  @formats [:pdf, :png, :svg]

  # PDFs have the time they were rendered in them, unless the document's date is none
  @no_date "#set document(date: none)\n"

  @items [%{name: "Widget", price: 25}, %{name: "Gadget", price: 5}]
  @statement %{number: 7, items: @items, signed_by: "Alex"}

  describe "templates without components" do
    for format <- @formats do
      test "render the same with an empty :components option (#{format})" do
        source = @no_date <> "= Title\nSome *text*, #link(\"https://example.com\")[a link] and $x^2$."
        assert render!(unquote(format), source, %{}, components: []) == render!(unquote(format), source)
      end

      test "render the same when the components they're given aren't imported (#{format})" do
        source = @no_date <> "= Title\n#lorem(40)\n#table(columns: 2, [a], [b])"

        assert render!(unquote(format), source, %{}, components: [Letterhead, Tables, Totals, Report, Callout]) ==
                 render!(unquote(format), source)
      end
    end

    test "document modules without components have none, and render as before" do
      assert Greeting.__typsty_components__() == []

      assigns = %{name: "World", items: ["one"]}
      assert Greeting.to_svg(assigns, components: []) == Greeting.to_svg(assigns)
      assert {:ok, [_svg]} = Greeting.to_svg(assigns, components: [Brand])
    end

    test "can import their own files next to components, at other paths" do
      source = """
      #import "brand.typ": blue as file-blue
      #import "lib/brand.typ": blue as lib-blue
      #import "components/brand.typ": blue
      #assert.eq(file-blue, red)
      #assert.eq(lib-blue, green)
      #assert.eq(blue, rgb("#1a4d8f"))
      """

      files = %{"brand.typ" => "#let blue = red", "lib/brand.typ" => "#let blue = green"}
      assert_renders(source, %{}, files: files, components: [Brand])
    end
  end

  describe "a component" do
    for format <- @formats do
      test "renders exactly what its code renders inline (#{format}, from a .typ file)" do
        body = ~s|#callout[Hello *world*]\n#callout(kind: "warning")[Careful]|
        imported = @no_date <> ~s|#import "components/callout.typ": callout\n| <> body
        inline = @no_date <> Callout.render().source <> body

        assert render!(unquote(format), imported, %{}, components: [Callout]) == render!(unquote(format), inline)
      end

      test "renders exactly what its code renders inline (#{format}, from a sigil)" do
        body = "#text(fill: blue)[#name]"
        imported = @no_date <> ~s|#import "components/brand.typ": blue, name\n| <> body
        inline = @no_date <> Brand.render().source <> body

        assert render!(unquote(format), imported, %{}, components: [Brand]) == render!(unquote(format), inline)
      end
    end

    test "with a :template option is read from that file" do
      assert Callout.__typsty_component__().name == "callout"
      assert %{file: file, source: "#let callout(body" <> _} = Callout.render()
      assert String.ends_with?(file, "test/support/components/sources/callout_source.typ")
    end
  end

  describe "importing a component" do
    # Each way of importing brand.typ, and how the name it defines is reached then
    @imports [
      {~s|#import "components/brand.typ": name|, "name"},
      {~s|#import "components/brand.typ"|, "brand.name"},
      {~s|#import "components/brand.typ": *|, "name"},
      {~s|#import "components/brand.typ" as b|, "b.name"},
      {~s|#import "components/brand.typ": name as brand-name|, "brand-name"},
      {~s|#import "/components/brand.typ": name|, "name"},
      {~s|#import "./components/brand.typ": name|, "name"},
      {~s|#import "components/../components/brand.typ": name|, "name"}
    ]

    for {import, name} <- @imports do
      test "works with #{import}" do
        # (The Typst code's # is concatenated: "#{" would be Elixir's interpolation)
        name = unquote(name)

        source =
          @no_date <> unquote(import) <> "\n#assert.eq(" <> name <> ", \"Acme\")\n#text(size: 20pt)[#" <> name <> "]"

        reference =
          @no_date <> ~s|#import "components/brand.typ": name\n#assert.eq(name, "Acme")\n#text(size: 20pt)[#name]|

        assert render!(:pdf, source, %{}, components: [Brand]) == render!(:pdf, reference, %{}, components: [Brand])
      end
    end

    test "with #include puts nothing on the page, as a component only defines things" do
      source = @no_date <> ~s|#include "components/brand.typ"\n#include "components/letterhead.typ"|

      assert render!(:pdf, source, %{}, components: [Letterhead]) == render!(:pdf, @no_date)
      assert render!(:png, source, %{}, components: [Letterhead]) == render!(:png, @no_date)
    end

    test "works from the template's own files, by relative and absolute paths" do
      files = %{
        "helpers/relative.typ" => ~s|#import "../components/brand.typ": name\n#let shout() = upper(name)|,
        "helpers/absolute.typ" => ~s|#import "/components/brand.typ": name\n#let whisper() = lower(name)|
      }

      source = """
      #import "helpers/relative.typ": shout
      #import "helpers/absolute.typ": whisper
      #assert.eq(shout(), "ACME")
      #assert.eq(whisper(), "acme")
      """

      assert_renders(source, %{}, files: files, components: [Brand])
    end
  end

  describe "components that use other components" do
    test "get the components they list, which documents needn't list" do
      # letterhead.typ imports brand.typ as a sibling, totals.typ imports money.typ as a
      # sibling and brand.typ by its absolute path
      source = """
      #import "components/letterhead.typ": letterhead, signature
      #import "components/totals.typ": total, totals
      #show: letterhead.with(title: [Statement])
      #assert.eq(total(assigns.items), 30)
      #totals(assigns.items)
      #signature("Alex")
      """

      assert_renders(source, %{items: @items}, components: [Letterhead, Totals])
    end

    test "let documents import the components they list too" do
      source = """
      #import "components/money.typ": money
      #import "components/brand.typ": blue
      #assert.eq(repr(money(12.345)), repr([\\$12.35]))
      #assert.eq(blue, rgb("#1a4d8f"))
      """

      assert_renders(source, %{}, components: [Totals])
    end

    test "render the same as the components' code inline" do
      imported = @no_date <> ~s|#import "components/totals.typ": totals\n#totals(assigns.items, currency: "€")|

      inline =
        @no_date <>
          """
          #let money(amount, currency: "$") = [#currency#calc.round(amount, digits: 2)]
          #let blue = rgb("#1a4d8f")
          #let total(items) = items.map(item => item.price).sum(default: 0)
          #let totals(items, currency: "$") = text(fill: blue)[*Total:* #money(total(items), currency: currency)]
          #totals(assigns.items, currency: "€")
          """

      for format <- @formats do
        assert render!(format, imported, %{items: @items}, components: [Totals]) ==
                 render!(format, inline, %{items: @items})
      end
    end

    test "that share a component get it once" do
      # Letterhead and Totals both list Brand, and Statement lists Letterhead
      assert {:ok, _svg} = Statement.to_svg(@statement, components: [Totals, Brand, Money, Letterhead])
    end
  end

  describe "template functions from components" do
    test "lay out every page, as the same code inline does" do
      items = for i <- 1..60, do: %{name: "Item #{i}", price: i}

      imported =
        ~s|#import "components/letterhead.typ": letterhead\n#show: letterhead.with(title: [Statement])\n#table(columns: 2, ..assigns.items.map(item => (item.name, str(item.price))).flatten())|

      inline = """
      #let letterhead(title: none, body) = {
        set page(
          header: text(fill: rgb("#1a4d8f"))[Acme #h(1fr) #title],
          footer: context [Page #counter(page).display() of #counter(page).final().first()],
        )
        set text(size: 10pt)
        body
      }
      #show: letterhead.with(title: [Statement])
      #table(columns: 2, ..assigns.items.map(item => (item.name, str(item.price))).flatten())
      """

      pages = render!(:png, imported, %{items: items}, components: [Letterhead])
      assert length(pages) > 1
      assert pages == render!(:png, inline, %{items: items})

      # The header and footer change the pages: without the letterhead, they're different
      plain = ~s|#table(columns: 2, ..assigns.items.map(item => (item.name, str(item.price))).flatten())|
      assert hd(render!(:png, plain, %{items: items})) != hd(pages)
    end

    test "set the document's metadata, headings and pages, from the assigns" do
      assigns = %{
        title: "Annual Report 2026",
        authors: ["Ada Lovelace", "Grace Hopper"],
        items: @items,
        currency: "€"
      }

      assert {:ok, pdf} = AnnualReport.to_pdf(assigns)

      assert PDF.info(pdf) == %{
               "Title" => "Annual Report 2026",
               "Author" => "Ada Lovelace, Grace Hopper",
               "Creator" => "Typst #{Typsty.typst_version()}"
             }

      assert PDF.page_count(pdf) == 2
      assert PDF.outline(pdf) == [{"1. Overview", []}, {"2. Totals", []}]

      # The report sets the date to none, so its PDFs are the same every time
      assert AnnualReport.to_pdf(assigns) == {:ok, pdf}
      assert {:ok, other} = AnnualReport.to_pdf(%{assigns | title: "Another title"})
      assert PDF.info(other)["Title"] == "Another title"
    end
  end

  describe "data passed to components" do
    test "reaches them as arguments, whatever its type" do
      source = """
      #import "components/totals.typ": total
      #import "components/report.typ": summarize
      #assert.eq(total(assigns.items), assigns.total)
      #assert.eq(summarize(assigns.items), (count: assigns.items.len(), total: assigns.total))
      """

      for prices <- [[25, 5], [Decimal.new("19.99"), Decimal.new("5.01")], [1.5, 2.25], []] do
        items = Enum.map(prices, &%{name: "Item", price: &1})

        total =
          case prices do
            [] -> 0
            [%Decimal{} | _] -> Enum.reduce(prices, &Decimal.add/2)
            _numbers -> Enum.sum(prices)
          end

        assert_renders(source, %{items: items, total: total}, components: [Totals, Report])
      end
    end

    test "can be content and functions, which render as they do inline" do
      imported =
        @no_date <>
          ~s|#import "components/extras.typ": each\n#import "components/callout.typ": callout\n| <>
          ~s|#callout[*Order* #each(assigns.items, item => emph(item.name))]|

      inline =
        @no_date <>
          Callout.render().source <>
          ~s|#callout[*Order* #assigns.items.map(item => emph(item.name)).join([, ])]|

      assert render!(:pdf, imported, %{items: @items}, components: [Extras, Callout]) ==
               render!(:pdf, inline, %{items: @items})
    end

    test "computed by a component can set the document's metadata" do
      source = """
      #import "components/totals.typ": total
      #set document(title: "Total " + str(total(assigns.items)), date: none)
      Hello
      """

      assert {:ok, pdf} = Typsty.to_pdf(source, %{items: @items}, components: [Totals])
      assert PDF.info(pdf)["Title"] == "Total 30"
    end
  end

  describe "PDF output from components" do
    test "embeds the fonts components use, and keeps their links to allowed URLs" do
      :telemetry.attach("links-#{inspect(self())}", [:typsty, :render, :stop], &__MODULE__.send_stop/4, self())
      on_exit(fn -> :telemetry.detach("links-#{inspect(self())}") end)

      source = """
      #import "components/extras.typ": mono, site
      Plain text, #mono[code],
      #site("https://example.com/docs?page=1")[docs],
      #site("mailto:hello@example.com")[mail],
      #site("javascript:alert(1)")[a script]
      """

      assert {:ok, pdf} = Typsty.to_pdf(source, %{}, components: [Extras])
      assert "DejaVuSansMono" in PDF.fonts(pdf)
      assert "LibertinusSerif-Regular" in PDF.fonts(pdf)
      assert PDF.link_uris(pdf) == ["https://example.com/docs?page=1", "mailto:hello@example.com"]

      assert_receive {:stop, %{template: %{source: ^source}, diagnostics: [warning]}}
      assert warning.message =~ "a link to a javascript: URL was left out of the document"
    end
  end

  describe "warnings and errors in components" do
    test "warnings point at the line in the component" do
      :telemetry.attach("warnings-#{inspect(self())}", [:typsty, :render, :stop], &__MODULE__.send_stop/4, self())
      on_exit(fn -> :telemetry.detach("warnings-#{inspect(self())}") end)

      source = ~s|#import "components/extras.typ": fancy\n#fancy[Hello]|
      assert {:ok, _svg} = Typsty.to_svg(source, %{}, components: [Extras])

      assert_receive {:stop, %{template: %{source: ^source}, diagnostics: [warning]}}
      assert warning.message == "unknown font family: no such font"
      assert {warning.file, warning.line, warning.column} == {"test/support/components/extras.ex", 9, 35}
    end

    test "errors in a component that another one uses point at it, through the calls that led there" do
      source = ~s|#import "components/totals.typ": totals\n\n#totals(((name: "x", price: "a"),))|

      assert {:error, %RenderError{diagnostics: [diagnostic]}} = Typsty.to_pdf(source, %{}, components: [Totals])
      assert diagnostic.message =~ "expected integer, float, or decimal, found string"
      assert {diagnostic.file, diagnostic.line} == {"test/support/components/money.ex", 7}

      assert Enum.map(diagnostic.trace, &{&1.file, &1.line}) == [
               {"test/support/components/totals.typ", 7},
               {nil, 3}
             ]
    end

    test "errors in a document's .typ template and in its components point at their files" do
      assigns = %{title: "Report", authors: [], items: [%{name: "x"}], currency: "$"}

      assert {:error, %RenderError{diagnostics: [diagnostic]}} = AnnualReport.to_pdf(assigns)
      assert diagnostic.message =~ ~s(dictionary does not contain key "price")
      assert {diagnostic.file, diagnostic.line} == {"test/support/components/report.typ", 14}
      assert %{file: "test/support/documents/annual_report.typ", line: 6} = List.last(diagnostic.trace)
    end

    test "a document's template rendered on its own needs its components given" do
      template = Statement.render(@statement)

      assert {:error, %RenderError{diagnostics: [%Diagnostic{message: message}]}} = Typsty.to_svg(template)
      assert message =~ "/components/letterhead.typ is not one of the render's components"

      assert Typsty.to_svg(template, %{}, components: [Letterhead, Tables]) == Statement.to_svg(@statement)
    end
  end

  describe "document modules" do
    test "with a .typ template render their components" do
      assigns = %{title: "Report", authors: ["Ada"], items: @items, currency: "$"}
      assert {:ok, [_page_1, _page_2]} = AnnualReport.to_png(assigns)
      assert {:ok, [_page_1, _page_2]} = AnnualReport.to_svg(assigns)
    end

    test "can give their renders components by default, by overriding a render function" do
      assert {:ok, [svg]} = Branded.to_svg(%{customer: "Ada"})
      assert {:ok, [^svg]} = Branded.to_svg(%{customer: "Ada"}, components: [Tables])
      assert {:error, %RenderError{}} = Branded.to_png(%{customer: "Ada"})
    end
  end

  describe "renders at the same time" do
    test "don't mix up components with the same name" do
      source = ~s|#import "components/badge.typ": badge\n#text(size: 40pt, badge)|

      expected = %{
        BadgeA => render!(:svg, source, %{}, components: [BadgeA]),
        BadgeB => render!(:svg, source, %{}, components: [BadgeB])
      }

      assert expected[BadgeA] != expected[BadgeB]

      results =
        1..40
        |> Task.async_stream(
          fn i ->
            badge = if rem(i, 2) == 0, do: BadgeA, else: BadgeB
            {badge, render!(:svg, source, %{}, components: [badge])}
          end,
          max_concurrency: 8,
          ordered: false
        )
        |> Enum.map(fn {:ok, result} -> result end)

      for {badge, svg} <- results, do: assert(svg == expected[badge])
    end
  end

  describe "in a Typsty.Pool" do
    setup do
      pool = Module.concat(__MODULE__, "Pool#{System.unique_integer([:positive])}")
      start_supervised!({Typsty.Pool, name: pool, size: 2})
      %{pool: pool}
    end

    test "templates with components render what they render inside the VM", %{pool: pool} do
      cases = [
        {@no_date <> ~s|#import "components/brand.typ": blue, name\n#text(fill: blue, name)|, %{}, [Brand]},
        {@no_date <> ~s|#import "components/totals.typ": totals\n#totals(assigns.items)|, %{items: @items}, [Totals]},
        {@no_date <> ~s|#import "components/callout.typ": callout\n#callout[Hi]|, %{}, [Callout, Brand]},
        {@no_date <> "No components", %{}, []}
      ]

      for {source, assigns, components} <- cases, format <- @formats do
        assert render!(format, source, assigns, components: components, pool: pool) ==
                 render!(format, source, assigns, components: components)
      end
    end

    test "document modules with components render what they render inside the VM", %{pool: pool} do
      assigns = %{title: "Report", authors: ["Ada"], items: @items, currency: "$"}
      assert AnnualReport.to_pdf(assigns, pool: pool) == AnnualReport.to_pdf(assigns)
      assert Statement.to_svg(@statement, pool: pool) == Statement.to_svg(@statement)
    end

    test "errors in components point at the same lines as inside the VM", %{pool: pool} do
      source = ~s|#import "components/totals.typ": totals\n#totals(((name: "x", price: "a"),))|

      assert Typsty.to_pdf(source, %{}, components: [Totals], pool: pool) ==
               Typsty.to_pdf(source, %{}, components: [Totals])
    end
  end

  @doc false
  def send_stop(_event, _measurements, metadata, test), do: send(test, {:stop, metadata})

  defp assert_renders(source, assigns, opts) do
    case Typsty.to_svg(source, assigns, opts) do
      {:ok, _svgs} -> :ok
      {:error, error} -> flunk(Exception.message(error))
    end
  end

  # Renders, failing the test with Typst's diagnostics if it can't
  defp render!(format, source, assigns \\ %{}, opts \\ []) do
    result =
      case format do
        :pdf -> Typsty.to_pdf(source, assigns, opts)
        :png -> Typsty.to_png(source, assigns, opts)
        :svg -> Typsty.to_svg(source, assigns, opts)
      end

    case result do
      {:ok, output} -> output
      {:error, error} -> flunk(Exception.message(error))
    end
  end
end
