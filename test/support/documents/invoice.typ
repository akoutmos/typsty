#set page(width: 10cm, height: auto)

= Invoice #assigns.number

#table(
  columns: (1fr, auto),
  [*Item*], [*Price*],
  ..assigns.items.map(item => (item.name, [#item.price])).flatten(),
)

#let total = assigns.items.map(item => item.price).sum()
#assert.eq(type(total), decimal)
Total: #total
