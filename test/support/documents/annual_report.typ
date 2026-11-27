#import "components/report.typ": report, section, summarize
#import "components/totals.typ": totals
#show: report.with(title: assigns.title, author: assigns.authors)

#section[Overview][
  #summarize(assigns.items).count items.
]

#pagebreak()

#section[Totals][
  #totals(assigns.items, currency: assigns.currency)
]
