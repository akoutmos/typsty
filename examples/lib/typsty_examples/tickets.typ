#import "@preview/tiaoma:0.4.0": qrcode
#import "components/brand.typ": base, colors, label, logo

#let event = assigns.event
#let day(at) = at.display("[weekday repr:long], [month repr:long] [day padding:none], [year]")
#let time(at) = at.display("[hour repr:12 padding:none]:[minute] [period case:lower]")

#show: base
#set page(width: 20cm, height: 8cm, margin: 0pt)

#for (i, ticket) in assigns.tickets.enumerate() {
  if i > 0 { pagebreak() }

  grid(
    columns: (0.5cm, 1fr, 5.6cm),
    rows: 100%,
    // A band of the brand's color down the left edge
    rect(width: 100%, height: 100%, fill: colors.accent),
    block(height: 100%, inset: (x: 0.8cm, y: 0.7cm), {
      grid(
        columns: (auto, 1fr),
        column-gutter: 6pt,
        align: horizon,
        logo(height: 0.55cm), text(size: 9pt, fill: colors.muted)[Kestrel Labs presents],
      )
      v(6pt)
      text(size: 22pt, weight: "bold", event.name)
      linebreak()
      text(size: 10pt, fill: colors.muted, event.tagline)
      v(1fr)
      grid(
        columns: (1.15fr, 1fr),
        column-gutter: 14pt,
        row-gutter: 10pt,
        [#label[When]\ #day(event.starts_at)\ #time(event.starts_at) to #time(event.ends_at)],
        [#label[Where]\ #event.venue\ #text(size: 9pt, event.address)],

        [#label[Attendee]\ *#ticket.holder*], [#label[Ticket]\ #ticket.type · #ticket.admits],
      )
    }),
    // The stub, behind a perforation, with the code to scan
    block(
      height: 100%,
      width: 100%,
      inset: (x: 0.6cm, y: 0.6cm),
      stroke: (left: (paint: colors.rule, thickness: 1pt, dash: "dashed")),
      fill: colors.wash,
      align(center, {
        label[Admit one]
        v(4pt)
        qrcode("https://kestrel.example/t/" + ticket.code, width: 3.4cm)
        v(4pt)
        text(font: "DejaVu Sans Mono", size: 9pt, ticket.code)
        v(1fr)
        text(size: 8pt, fill: colors.muted)[Order #assigns.order.number\ Ticket #(i + 1) of #assigns.tickets.len()]
      }),
    ),
  )
}
