#set page(width: 10cm, height: auto)

= Invoice #number

#table(
  columns: (1fr, auto),
  [*Item*], [*Price*],
  ..items.map(item => (item.name, [#item.price])).flatten(),
)

#let total = items.map(item => item.price).sum()
#assert.eq(type(total), decimal)
Total: #total
