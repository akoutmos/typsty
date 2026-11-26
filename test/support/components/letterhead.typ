#import "brand.typ"

#let letterhead(title: none, body) = {
  set page(
    header: text(fill: brand.blue)[#brand.name #h(1fr) #title],
    footer: context [Page #counter(page).display() of #counter(page).final().first()],
  )
  set text(size: 10pt)
  body
}

#let signature(name) = [Best regards, #name.first()]
