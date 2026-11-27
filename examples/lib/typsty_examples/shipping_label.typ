#import "@preview/tiaoma:0.4.0": code128, data-matrix

// Black only, in a font that reads well at a thermal printer's resolution
#set text(font: "DejaVu Sans Mono", size: 9pt)
#set page(width: 4in, height: 6in, margin: 0.15in)

#let rule = line(length: 100%, stroke: 1.5pt)
#let small(body) = text(size: 7pt, weight: "bold", upper(body))
#let address(party) = [#party.name\ #party.address.join[\ ]]

#for (i, package) in assigns.packages.enumerate() {
  if i > 0 { pagebreak() }

  grid(
    columns: (1fr, auto),
    column-gutter: 6pt,
    [#small[From]\ #text(size: 8pt, address(assigns.from))],
    box(stroke: 2pt, inset: 6pt, text(size: 20pt, weight: "bold", assigns.service)),
  )
  v(2pt)
  rule

  pad(left: 4pt, y: 4pt, {
    small[Ship to]
    linebreak()
    text(size: 13pt, weight: "bold", address(assigns.to))
  })
  rule

  grid(
    columns: (auto, 1fr),
    column-gutter: 10pt,
    align: horizon,
    data-matrix(package.tracking + "|" + package.routing, width: 1.15in),
    {
      text(size: 26pt, weight: "bold", package.routing)
      linebreak()
      text(size: 8pt)[#assigns.carrier · #package.weight LB · PKG #(i + 1) OF #assigns.packages.len()]
    },
  )
  v(2pt)
  rule

  align(center, {
    small[#assigns.carrier tracking]
    v(2pt)
    // Stretched to the space it has, as a barcode of bars can be. By default, a barcode given
    // a width and a height is cropped to fit, losing the number printed under it
    code128(package.tracking, width: 100%, height: 1.15in, fit: "stretch", hrt: (size: 10pt))
  })
  v(1fr)
  rule
  grid(
    columns: (1fr, auto),
    text(size: 7.5pt)[Order #assigns.order\ Shipped #assigns.shipped_on.display("[year]-[month]-[day]")],
    align(right, text(size: 7.5pt)[Ref #package.reference]),
  )
}
