#import "@preview/tiaoma:0.4.0": qrcode
#import "components/brand.typ": base, colors, label, logo

#show: base
#set page(paper: "us-letter", flipped: true, margin: 0.5in)
#set align(center)

#let verify-url = "https://kestrel.example/verify/" + assigns.id

// A double frame, around the whole page
#block(
  width: 100%,
  height: 100%,
  stroke: 1.5pt + colors.ink,
  inset: 5pt,
  block(width: 100%, height: 100%, stroke: 0.5pt + colors.accent, inset: (x: 0.7in, y: 0.35in), {
    logo(height: 1cm)
    v(6pt)
    text(size: 10pt, fill: colors.muted, tracking: 0.3em)[KESTREL ACADEMY]

    v(0.2in)
    text(size: 32pt, weight: "bold")[Certificate of Completion]

    v(0.12in)
    text(size: 12pt, fill: colors.muted)[This certifies that]
    v(2pt)
    text(size: 36pt, style: "italic", assigns.recipient)
    v(-6pt)
    line(length: 60%, stroke: 0.5pt + colors.rule)

    v(4pt)
    text(size: 12pt, fill: colors.muted)[has completed the course]
    v(2pt)
    text(size: 18pt, weight: "bold", assigns.course)
    v(2pt)
    text(
      size: 11pt,
    )[#assigns.hours hours of instruction, completed on #assigns.completed_on.display("[month repr:long] [day padding:none], [year]")]

    v(1fr)

    grid(
      columns: (1fr, 1fr, 1fr),
      align: (center + bottom, center + bottom, center + bottom),
      {
        image("signature.svg", height: 0.6in)
        v(-4pt)
        line(length: 70%, stroke: 0.5pt + colors.ink)
        v(-2pt)
        text(size: 10pt)[*#assigns.instructor.name*\ #text(fill: colors.muted, assigns.instructor.title)]
      },
      // A seal, in the brand's color
      circle(radius: 0.48in, stroke: 2pt + colors.accent, inset: 0pt, align(center + horizon, circle(
        radius: 0.41in,
        stroke: 0.5pt + colors.accent,
        align(center + horizon, text(
          size: 7pt,
          weight: "bold",
          fill: colors.accent,
          tracking: 0.12em,
        )[KESTREL\ ACADEMY\ #assigns.completed_on.year()]),
      ))),
      {
        qrcode(verify-url, width: 0.75in)
        v(2pt)
        text(
          size: 8pt,
          fill: colors.muted,
        )[Certificate #assigns.id\ Verify at #link(verify-url)[kestrel.example/verify]]
      },
    )
  }),
)
