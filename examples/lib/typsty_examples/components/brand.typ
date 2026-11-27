// Text and surface colors, and the status colors that badges pair with a label
#let colors = (
  ink: rgb("#1f2328"),
  muted: rgb("#59636e"),
  rule: rgb("#d1d9e0"),
  wash: rgb("#f6f8fa"),
  accent: rgb("#2a78d6"),
  good: rgb("#0b8a0b"),
  critical: rgb("#d03b3b"),
)

// The colors chart series get, in this order. Checked to stay apart for color-blind readers
#let series = (rgb("#2a78d6"), rgb("#eb6834"), rgb("#1baf7a"), rgb("#eda100"))

// Fonts that come with Typst, so documents look the same on every machine
#let fonts = (serif: "Libertinus Serif", mono: "DejaVu Sans Mono")

#let logo(height: 1cm) = image("brand/logo.svg", height: height)

// A small label in capitals, above a value or a block
#let label(body) = text(size: 7.5pt, weight: "bold", fill: colors.muted, tracking: 0.08em, upper(body))

// The text every document starts from. Apply it with a show rule: #show: base
#let base(body) = {
  set text(font: fonts.serif, size: 10.5pt, fill: colors.ink)
  set par(leading: 0.6em)
  show raw: set text(font: fonts.mono, size: 0.9em)
  body
}
