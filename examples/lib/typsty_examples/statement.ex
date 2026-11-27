defmodule TypstyExamples.Statement do
  @moduledoc """
  A monthly account statement: a summary, spending by category, and every transaction with
  the balance after it.

  Unlike the other examples, its template is in `render/1`, with the `~TYPST` sigil, which
  lets it work out values with Elixir before the template runs: the running balances, the
  totals in and out, and the spending in each category.

  Its assigns:

  - `:company`, and `:account`: a map with the `:holder`, the holder's `:address` (a list
    of lines), the account's `:name` and the `:last4` digits of its number
  - `:starts_on` and `:ends_on` - the first and last days of the statement's period
  - `:opening_balance` - a `Decimal`
  - `:transactions` - maps with a `:date`, a `:description`, a `:category` and an
    `:amount`, a `Decimal` that's negative for money out, in date order
  """
  use Typsty,
    components: [
      TypstyExamples.Components.Brand,
      TypstyExamples.Components.Letterhead,
      TypstyExamples.Components.Money
    ]

  def render(assigns) do
    {transactions, closing_balance} =
      Enum.map_reduce(assigns.transactions, assigns.opening_balance, fn transaction, balance ->
        balance = Decimal.add(balance, transaction.amount)
        {Map.put(transaction, :balance, balance), balance}
      end)

    {money_in, money_out} = Enum.split_with(assigns.transactions, &Decimal.positive?(&1.amount))

    spending =
      money_out
      |> Enum.group_by(& &1.category, &Decimal.negate(&1.amount))
      |> Enum.map(fn {category, amounts} -> %{category: category, amount: Enum.reduce(amounts, &Decimal.add/2)} end)
      |> Enum.sort_by(& &1.amount, {:desc, Decimal})

    assigns =
      Map.merge(assigns, %{
        transactions: transactions,
        closing_balance: closing_balance,
        money_in: sum(money_in),
        money_out: Decimal.negate(sum(money_out)),
        spending: spending
      })

    ~TYPST"""
    #import "components/brand.typ": colors, label
    #import "components/letterhead.typ": letterhead
    #import "components/money.typ": money

    #let account = assigns.account
    #let day(date) = date.display("[month repr:short] [day padding:none]")
    #let long-date(date) = date.display("[month repr:long] [day padding:none], [year]")

    #show: letterhead.with(company: assigns.company, title: [#account.name ···· #account.last4])

    #grid(
      columns: (1fr, auto),
      align: (left + bottom, right + bottom),
      [
        #text(size: 22pt, weight: "bold")[Account statement]\
        #text(size: 11pt, fill: colors.muted)[#long-date(assigns.starts_on) to #long-date(assigns.ends_on)]
      ],
      [
        #label[Account holder]\
        *#account.holder*\
        #account.address.join[\ ]
      ],
    )

    #v(12pt)

    #grid(
      columns: (1fr,) * 4,
      column-gutter: 8pt,
      ..(
        ([Opening balance], assigns.opening_balance),
        ([Money in], assigns.money_in),
        ([Money out], assigns.money_out),
        ([Closing balance], assigns.closing_balance),
      ).map(((name, amount)) => block(width: 100%, fill: colors.wash, radius: 4pt, inset: 9pt)[
        #label(name)\
        #text(size: 14pt, weight: "bold", money(amount))
      ]),
    )

    #v(10pt)

    // Spending by category, as bars measured against the largest
    #label[Spending by category]
    #v(2pt)
    #let largest = calc.max(..assigns.spending.map(category => category.amount), decimal("0.01"))
    #grid(
      columns: (auto, 1fr, auto),
      column-gutter: 10pt,
      row-gutter: 5pt,
      align: (left + horizon, left + horizon, right + horizon),
      ..assigns
        .spending
        .map(category => (
          category.category,
          box(width: 100%, height: 6pt, fill: colors.wash, radius: 3pt, box(
            width: float(category.amount / largest) * 100%,
            height: 6pt,
            fill: colors.accent,
            radius: 3pt,
          )),
          money(category.amount),
        ))
        .flatten(),
    )

    #v(12pt)

    #table(
      columns: (auto, 1fr, auto, auto),
      align: (left, left, right, right),
      inset: (x: 6pt, y: 5pt),
      stroke: none,
      fill: (_, y) => if y > 0 and calc.even(y) { colors.wash },
      table.header(..([Date], [Description], [Amount], [Balance]).map(name => label(name))),
      table.hline(stroke: 0.8pt + colors.ink),
      [], [Opening balance], [], money(assigns.opening_balance),
      ..assigns
        .transactions
        .map(transaction => (
          day(transaction.date),
          [#transaction.description #h(4pt) #text(size: 8pt, fill: colors.muted, transaction.category)],
          if transaction.amount > 0 { "+" + money(transaction.amount) } else { money(transaction.amount) },
          money(transaction.balance),
        ))
        .flatten(),
      table.hline(stroke: 0.8pt + colors.ink),
      [], strong[Closing balance], [], strong(money(assigns.closing_balance)),
    )
    """
  end

  defp sum(transactions), do: Enum.reduce(transactions, Decimal.new(0), &Decimal.add(&1.amount, &2))
end
