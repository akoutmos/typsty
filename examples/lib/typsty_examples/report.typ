#import "components/brand.typ": base, colors, label, logo
#import "components/charts.typ": bar-chart, column-chart, line-chart
#import "components/money.typ": money

// A ratio as a percentage, with one decimal: 0.4896 is 49.0%
#let percent(ratio) = {
  let (whole, ..tenths) = str(calc.round(float(ratio) * 100, digits: 1)).split(".")
  whole + "." + tenths.at(0, default: "0") + "%"
}

// A change from the last period, with an arrow, so it doesn't rely on its color alone
#let change(ratio) = {
  let (arrow, color) = if ratio >= 0 { (sym.triangle.filled.t, colors.good) } else {
    (sym.triangle.filled.b, colors.critical)
  }
  text(fill: color, size: 0.85em, arrow)
  h(2pt)
  percent(calc.abs(ratio))
}

#set document(title: assigns.title + " — " + assigns.period, author: assigns.company.name)
#show: base
#set par(justify: true)
#set heading(numbering: "1.")

// Sticky, like Typst's own headings, so a heading never ends a page apart from its text
#show heading.where(level: 1): it => block(sticky: true, above: 26pt, below: 14pt, text(size: 20pt, weight: "bold", {
  if it.numbering != none {
    text(fill: colors.accent, counter(heading).display(it.numbering))
    h(8pt)
  }
  it.body
}))

#show figure.caption: set text(size: 9pt, fill: colors.muted)
#show figure: set block(spacing: 18pt)

// The cover, a page of its own
#page(paper: "us-letter", margin: 0pt)[
  #block(width: 100%, height: 62%, fill: colors.ink, inset: (x: 2.2cm, top: 2.4cm, bottom: 1.6cm))[
    #grid(
      columns: 2,
      column-gutter: 8pt,
      align: horizon,
      logo(height: 1.1cm), text(size: 14pt, weight: "bold", fill: white, assigns.company.name),
    )
    #v(1fr)
    #text(size: 12pt, fill: colors.rule, tracking: 0.12em, upper(assigns.period))
    #v(4pt)
    #text(size: 38pt, weight: "bold", fill: white, assigns.title)
  ]
  #block(inset: (x: 2.2cm, top: 1.2cm))[
    #grid(
      columns: (1fr, 1fr, 1fr),
      row-gutter: 6pt,
      label[Prepared for], label[Prepared by], label[Published],
      assigns.prepared_for,
      assigns.prepared_by,
      assigns.published_on.display("[month repr:long] [day padding:none], [year]"),
    )
  ]
  #place(bottom + left, dx: 2.2cm, dy: -1.6cm, text(
    size: 8pt,
    fill: colors.muted,
  )[Confidential. For internal use only.])
]

#set page(
  paper: "us-letter",
  margin: (x: 2.2cm, top: 2.6cm, bottom: 2.4cm),
  header: {
    set text(size: 8.5pt, fill: colors.muted)
    grid(
      columns: (1fr, auto),
      assigns.title, assigns.period,
    )
    v(-2pt)
    line(length: 100%, stroke: 0.5pt + colors.rule)
  },
  footer: context {
    set text(size: 8.5pt, fill: colors.muted)
    grid(
      columns: (1fr, auto),
      [#assigns.company.name · Confidential], counter(page).display(),
    )
  },
)
#counter(page).update(1)

#outline(title: text(size: 20pt)[Contents], indent: auto)
#pagebreak()

= Executive summary

#lorem(70)

#v(6pt)
#grid(
  columns: (1fr,) * assigns.kpis.len(),
  column-gutter: 10pt,
  ..assigns.kpis.map(kpi => block(
    width: 100%,
    fill: colors.wash,
    radius: 4pt,
    inset: 10pt,
    {
      label(kpi.label)
      v(2pt)
      text(size: 20pt, weight: "bold", kpi.value)
      linebreak()
      text(size: 8.5pt, fill: colors.muted)[#change(kpi.change) vs. last quarter]
    },
  )),
)
#v(6pt)

#lorem(90)

#lorem(60)

= Revenue

#lorem(55)

#figure(
  column-chart(assigns.monthly_revenue, x: "month", y: "revenue", prefix: "$"),
  kind: image,
  caption: [Revenue by month, over the last twelve months],
)

#lorem(80)

== Recurring revenue

#lorem(70)

== Services

#lorem(50)

= Customers

#lorem(50)

#figure(
  line-chart(assigns.accounts, x: "month", y: "accounts", series-field: "plan", names: assigns.plans),
  kind: image,
  caption: [Active accounts by plan, at the end of each month],
)

#lorem(75)

= Regions

#lorem(40)

#let total = assigns.regions.map(region => region.revenue).sum()

#figure(
  bar-chart(assigns.regions, category: "region", value: "revenue", format: "$,.0f", height: 4cm),
  kind: image,
  caption: [Revenue by region, this quarter],
)

#figure(
  table(
    columns: (1fr, auto, auto, auto),
    align: (left, right, right, right),
    stroke: (_, y) => if y > 0 { (top: 0.5pt + colors.rule) },
    inset: (x: 6pt, y: 6pt),
    table.header(..([Region], [Revenue], [Share], [Growth]).map(name => label(name))),
    table.hline(stroke: 0.8pt + colors.ink),
    ..assigns
      .regions
      .map(region => (
        region.region,
        money(region.revenue, cents: false),
        percent(region.revenue / total),
        change(region.growth),
      ))
      .flatten(),
    table.hline(stroke: 0.8pt + colors.ink),
    strong[Total], strong(money(total, cents: false)), [100%], [],
  ),
  caption: [The figures behind the chart above],
)

#lorem(60)

= Outlook

#lorem(60)

The priorities for next quarter:

#for size in (14, 18, 12, 16) [
  - #lorem(size)
]

#lorem(45)
