#import "components/brand.typ": base, colors, fonts

#show: base
#set text(size: 8pt)
#set par(leading: 0.5em)
#set page(
  paper: "us-letter",
  flipped: true,
  margin: (x: 1.1cm, top: 1.1cm, bottom: 1.3cm),
  columns: 3,
  footer: {
    set text(size: 7.5pt, fill: colors.muted)
    grid(
      columns: (1fr, auto),
      [#assigns.title #assigns.version], assigns.url,
    )
  },
)
#set columns(gutter: 0.5cm)

// Code in a snippet is highlighted, on a tinted background
#show raw.where(block: true): it => block(
  width: 100%,
  fill: colors.wash,
  radius: 3pt,
  inset: (x: 6pt, y: 4pt),
  text(size: 6.8pt, it),
)

#place(top, scope: "parent", float: true, clearance: 12pt, block(width: 100%, {
  grid(
    columns: (auto, 1fr, auto),
    align: (left + bottom, left + bottom, right + bottom),
    column-gutter: 10pt,
    text(size: 24pt, weight: "bold", assigns.title),
    text(size: 13pt, fill: colors.muted, assigns.subtitle),
    text(size: 9pt, fill: colors.muted)[Version #assigns.version · #assigns.url],
  )
  v(-4pt)
  line(length: 100%, stroke: 2pt + colors.accent)
}))

#for section in assigns.sections {
  block(
    width: 100%,
    breakable: false,
    stroke: 0.5pt + colors.rule,
    radius: 4pt,
    clip: true,
    below: 8pt,
    {
      block(
        width: 100%,
        fill: colors.ink,
        inset: (x: 7pt, y: 4pt),
        below: 0pt,
        text(size: 9.5pt, weight: "bold", fill: white, section.title),
      )
      // An entry is a note, a snippet of code, or both
      block(inset: 6pt, width: 100%, stack(spacing: 7pt, ..section.entries.map(entry => stack(
        spacing: 3pt,
        ..(
          entry.at("note", default: none),
          if entry.at("code", default: none) != none {
            raw(entry.code, lang: entry.at("lang", default: none), block: true)
          },
        ).filter(part => part != none),
      ))))
    },
  )
}
