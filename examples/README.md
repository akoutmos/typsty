# Typsty examples

Documents that web applications commonly generate, rendered with
[Typsty](../README.md) from sample data. Each one is a document module with its
template, the way it would be in your application, and they share components
for their branding, letterhead, money and charts.

| Example | What it shows |
| ------- | ------------- |
| [Invoice](lib/typsty_examples/invoice.ex) | Line items and totals worked out with decimals, a status badge, a table that continues across pages, a QR code to pay online, and a struct passed with `Typsty.Encoder` |
| [Report](lib/typsty_examples/report.ex) | A cover, a table of contents, headline figures, and charts drawn with the [nulite](https://typst.app/universe/package/nulite) package (Vega-Lite), with placeholder text |
| [Cheat sheet](lib/typsty_examples/cheat_sheet.ex) | A one-page reference in three columns, with highlighted code, for any subject. The sample is a cheat sheet for Typsty |
| [Account statement](lib/typsty_examples/statement.ex) | A template in `render/1`, which works out running balances and totals in Elixir first, and spending by category drawn without a chart package |
| [Event tickets](lib/typsty_examples/tickets.ex) | One ticket per page, with a stub and a QR code drawn with the [tiaoma](https://typst.app/universe/package/tiaoma) package |
| [Shipping labels](lib/typsty_examples/shipping_label.ex) | 4 × 6 inch labels for thermal printers, with Code 128 and Data Matrix barcodes |
| [Certificate](lib/typsty_examples/certificate.ex) | A landscape certificate, with a signature passed with the `:files` option, and a QR code to verify it |

The components are in [lib/typsty_examples/components](lib/typsty_examples/components):

- `Brand` has the colors, fonts and logo, which are in its own folder
  (`brand/logo.svg`).
- `Letterhead` puts a header and footer on the pages of business documents.
- `Money` formats amounts, and is written with the `~TYPST` sigil rather than a
  `.typ` file.
- `Charts` wraps nulite with the brand's look, and shows that components can
  import packages.

The sample data is in [samples.ex](lib/typsty_examples/samples.ex).

## Running them

Typsty is a dependency on the parent directory, a development version, so its
NIF is built from source: you'll need [Rust](https://www.rust-lang.org/tools/install).

```shell
cd examples
mix deps.get
mix typsty.packages.get    # the packages listed in config/config.exs
mix examples.render        # writes output/<name>.pdf
```

`mix examples.render invoice report` renders some of them, `--png` writes a PNG
of each page too, and `--pool` renders them in a `Typsty.Pool`, rather than in
the VM. `mix test` renders each one, checking that it renders without warnings,
to the pages it should, and the same in a pool as in the VM.

The examples use only the fonts that come with Typst (`system_fonts: false`, in
[config/runtime.exs](config/runtime.exs)), so they look the same on every
machine. To use your own, put them in `priv/fonts` and add that directory to
the `:font_paths` option.

## In a Phoenix controller

```elixir
def show(conn, %{"id" => id}) do
  invoice = Billing.get_invoice!(id)

  case TypstyExamples.Invoice.to_pdf(Billing.invoice_assigns(invoice)) do
    {:ok, pdf} ->
      send_download(conn, {:binary, pdf}, filename: "invoice-#{invoice.number}.pdf", content_type: "application/pdf")

    # The server was too busy to render it in time
    {:error, %Typsty.RenderError{reason: reason}} when reason in [:busy, :timeout] ->
      send_resp(conn, 503, "Please try again in a moment")

    {:error, error} ->
      raise error
  end
end
```

## Things to know about the packages

- nulite runs Vega-Lite in a JavaScript engine, which takes JSON's types:
  decimals, dates and `none` can't be passed to it as they are. The `Charts`
  component converts them (`plain/1` in `charts.typ`). A chart that can't be
  drawn fails with `plugin errored with: encode error`, whatever the cause.
- nulite's first chart in a VM, or in a new pool worker, takes about half a
  second, while its JavaScript engine starts. Typst caches charts, so a chart
  drawn again from the same data is nearly free.
- Vega-Lite's own sort by value (`sort: "-x"`) fails in a chart with layers, so
  `bar-chart` puts its bars in order itself.
- A tiaoma barcode given both a width and a height is cropped to fit by
  default, which can cut off the number printed under it. Give it one of them,
  or `fit: "stretch"` for a barcode of bars.
