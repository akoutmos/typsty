#import "@preview/tiaoma:0.4.0": qrcode
#import "components/brand.typ": colors, label
#import "components/letterhead.typ": letterhead
#import "components/money.typ": money

#let (company, customer, lines) = assigns
#let date(day) = day.display("[month repr:long] [day padding:none], [year]")

#show: letterhead.with(company: company, title: [Invoice #assigns.number])

// The totals, from the lines. Amounts are decimals, so they add up to the cent
#let subtotal = lines.map(line => line.quantity * line.unit_price).sum(default: decimal("0"))
#let discount = assigns.at("discount", default: none)
#let taxable = subtotal - if discount == none { decimal("0") } else { discount.amount }
#let tax = calc.round(taxable * assigns.tax_rate, digits: 2)
#let total = taxable + tax
#let balance = total - assigns.amount_paid

#let status = (
  paid: (text: "Paid", color: colors.good),
  overdue: (text: "Overdue", color: colors.critical),
  open: (text: "Due " + date(assigns.due_on), color: colors.accent),
).at(assigns.status)

#grid(
  columns: (1fr, auto),
  align: (left + bottom, right + bottom),
  [
    #text(size: 26pt, weight: "bold")[Invoice]\
    #text(size: 11pt, fill: colors.muted)[No. #assigns.number]
  ],
  box(
    stroke: 1.2pt + status.color,
    radius: 3pt,
    inset: (x: 10pt, y: 6pt),
    text(size: 11pt, weight: "bold", fill: status.color, tracking: 0.06em, upper(status.text)),
  ),
)

#v(14pt)

#grid(
  columns: (1fr, 1fr),
  column-gutter: 24pt,
  [
    #label[Billed to]\
    *#customer.name*\
    #if customer.contact != none [Attn: #customer.contact\ ]
    #customer.address.join[\ ]\
    #customer.email
  ],
  {
    set align(right)
    grid(
      columns: (auto, auto),
      column-gutter: 12pt,
      row-gutter: 7pt,
      align: (right, right),
      label[Issued], date(assigns.issued_on),
      label[Due], date(assigns.due_on),
      ..if assigns.at("purchase_order", default: none) != none {
        (label[Purchase order], assigns.purchase_order)
      },
      label[Balance due], strong(money(balance)),
    )
  },
)

#v(18pt)

#table(
  columns: (1fr, auto, auto, auto),
  align: (left, right, right, right),
  inset: (x: 6pt, y: 7pt),
  stroke: (_, y) => if y > 0 { (top: 0.5pt + colors.rule) },
  table.header(..([Description], [Qty], [Unit price], [Amount]).map(heading => label(heading))),
  table.hline(stroke: 0.8pt + colors.ink),
  ..lines
    .map(line => (
      [
        #line.description
        #if line.at("details", default: none) != none {
          linebreak()
          text(size: 9pt, fill: colors.muted, line.details)
        }
      ],
      str(line.quantity),
      money(line.unit_price),
      money(line.quantity * line.unit_price),
    ))
    .flatten(),
)

#v(4pt)

#align(right, block(width: 48%, {
  set text(size: 10pt)
  let row(name, amount, bold: false) = {
    let cell(body) = if bold { strong(body) } else { body }
    (cell(name), cell(amount))
  }
  grid(
    columns: (1fr, auto),
    column-gutter: 18pt,
    row-gutter: 8pt,
    align: right,
    ..row([Subtotal], money(subtotal)),
    ..if discount != none { row(discount.label, "−" + money(discount.amount)) },
    ..row([Tax (#str(calc.round(float(assigns.tax_rate) * 100, digits: 3))%)], money(tax)),
    grid.hline(stroke: 0.8pt + colors.ink),
    ..row([Total], money(total), bold: true),
    ..if assigns.amount_paid > 0 {
      (..row([Paid], "−" + money(assigns.amount_paid)), grid.hline(stroke: 0.5pt + colors.rule))
      row([Balance due], money(balance), bold: true)
    },
  )
}))

#v(1fr)

#let notes = assigns.at("notes", default: none)
#let notes = if notes != none { text(size: 9pt, fill: colors.muted, notes) }

#if balance <= 0 {
  notes
} else {
  block(
    breakable: false,
    fill: colors.wash,
    radius: 4pt,
    inset: 12pt,
    width: 100%,
    grid(
      columns: (auto, 1fr),
      column-gutter: 14pt,
      align: horizon,
      qrcode(assigns.payment_url, width: 2.2cm),
      [
        #label[Pay online]\
        Scan the code, or go to #link(assigns.payment_url).
        #if notes != none [
          #v(2pt)
          #notes
        ]
      ],
    ),
  )
}
