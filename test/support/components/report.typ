// A report: its metadata, numbered headings and page numbers, and its sections
#let report(title: none, author: (), body) = {
  set document(title: title, author: author, date: none)
  set heading(numbering: "1.")
  set page(numbering: "1 of 1")
  body
}

#let section(title, body) = {
  heading(title)
  body
}

#let summarize(items) = (count: items.len(), total: items.map(item => item.price).sum(default: 0))
