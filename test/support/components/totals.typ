// The total of a list of items, in the brand's color
#import "money.typ": money
#import "/components/brand.typ": blue

#let total(items) = items.map(item => item.price).sum(default: 0)

#let totals(items, currency: "$") = text(fill: blue)[*Total:* #money(total(items), currency: currency)]
