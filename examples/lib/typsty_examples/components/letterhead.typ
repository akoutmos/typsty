#import "brand.typ": base, colors, logo

// Lays out every page after it with the company's logo and name, and the document's title,
// at the top, and its address and the page number at the bottom:
//
//     #show: letterhead.with(company: assigns.company, title: [Invoice])
//
// `company` is a dictionary with a name, address (a list of lines), email and website.
#let letterhead(company: (:), title: none, body) = {
  set page(
    paper: "us-letter",
    margin: (top: 2.9cm, bottom: 2.5cm, x: 2.2cm),
    header: {
      grid(
        columns: (auto, 1fr, auto),
        align: horizon,
        column-gutter: 8pt,
        logo(height: 0.8cm), text(size: 12pt, weight: "bold", company.name), text(size: 9pt, fill: colors.muted, title),
      )
      v(-2pt)
      line(length: 100%, stroke: 0.5pt + colors.rule)
    },
    footer: context {
      set text(size: 8pt, fill: colors.muted)
      line(length: 100%, stroke: 0.5pt + colors.rule)
      v(-2pt)
      grid(
        columns: (1fr, auto),
        (company.address.join(", "), company.email, company.website).join[ #sym.dot.c ],
        [Page #counter(page).display() of #counter(page).final().first()],
      )
    },
  )
  show: base
  body
}
