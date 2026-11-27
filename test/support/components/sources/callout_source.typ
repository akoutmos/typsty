#let callout(body, kind: "note") = block(
  fill: if kind == "warning" { rgb("#fff3cd") } else { luma(240) },
  inset: 8pt,
  radius: 4pt,
  [*#upper(kind):* #body],
)
