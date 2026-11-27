defmodule TypstyExamplesTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias TypstyExamples.{Components, Invoice, Samples, Statement}

  # The pages each example's sample data fills
  @pages %{
    "invoice" => 1,
    "report" => 5,
    "cheat_sheet" => 1,
    "statement" => 2,
    "tickets" => 3,
    "shipping_label" => 2,
    "certificate" => 1
  }

  test "every example is tested" do
    assert Enum.map(TypstyExamples.all(), &elem(&1, 0)) |> Enum.sort() == @pages |> Map.keys() |> Enum.sort()
  end

  for {name, _module, _assigns, _opts} <- TypstyExamples.all() do
    describe name do
      @describetag example: name

      test "renders its pages, without warnings from Typst", %{example: name} do
        {^name, module, assigns, opts} = TypstyExamples.get(name)

        log =
          capture_log(fn ->
            assert {:ok, <<"%PDF-", _::binary>>} = module.to_pdf(assigns, opts)
            assert {:ok, pages} = module.to_svg(assigns, opts)
            send(self(), {:pages, length(pages)})
          end)

        assert_received {:pages, pages}
        assert pages == @pages[name]
        assert log == ""
      end

      test "renders the same pages in a pool as in the VM", %{example: name} do
        {^name, module, assigns, opts} = TypstyExamples.get(name)

        assert module.to_svg(assigns, opts) == module.to_svg(assigns, Keyword.put(opts, :pool, TypstyExamples.Pool))
      end
    end
  end

  describe "the invoice" do
    test "can leave out its optional fields" do
      assigns = Map.drop(Samples.invoice(), [:discount, :purchase_order, :notes])

      assert {:ok, [_page]} = Invoice.to_svg(assigns)
    end

    test "can be paid, or overdue" do
      for status <- [:paid, :overdue] do
        assigns = %{Samples.invoice() | status: status, amount_paid: Decimal.new("100.00")}
        assert {:ok, [_page]} = Invoice.to_svg(assigns)
      end
    end

    test "with more lines than fit on a page, continues on the next" do
      line = %{description: "Consulting", quantity: 1, unit_price: Decimal.new("150.00")}
      assigns = %{Samples.invoice() | lines: List.duplicate(line, 60)}

      assert {:ok, [_, _ | _]} = Invoice.to_svg(assigns)
    end
  end

  describe "the statement" do
    test "works out the balances, the totals and the spending before its template runs" do
      transactions = [
        %{date: ~D[2026-10-01], description: "Rent", category: "Rent", amount: Decimal.new("-1000.00")},
        %{date: ~D[2026-10-02], description: "Payment", category: "Customers", amount: Decimal.new("250.50")},
        %{date: ~D[2026-10-03], description: "Flight", category: "Travel", amount: Decimal.new("-300.25")},
        %{date: ~D[2026-10-04], description: "Hotel", category: "Travel", amount: Decimal.new("-900.00")}
      ]

      assigns =
        Statement.render(%{Samples.statement() | opening_balance: Decimal.new("5000.00"), transactions: transactions}).assigns

      assert Enum.map(assigns.transactions, &Decimal.to_string(&1.balance)) == [
               "4000.00",
               "4250.50",
               "3950.25",
               "3050.25"
             ]

      assert Decimal.to_string(assigns.closing_balance) == "3050.25"
      assert Decimal.to_string(assigns.money_in) == "250.50"
      assert Decimal.to_string(assigns.money_out) == "2200.25"

      assert Enum.map(assigns.spending, &{&1.category, Decimal.to_string(&1.amount)}) == [
               {"Travel", "1200.25"},
               {"Rent", "1000.00"}
             ]
    end

    test "can have no transactions" do
      assert {:ok, [_page]} = Statement.to_svg(%{Samples.statement() | transactions: []})
    end
  end

  # Typst code is tested with Typst's own assertions: a failed one fails the render
  describe "money" do
    test "formats amounts with their thousands separated, rounded to cents or dollars" do
      assert_typst([Components.Money], ~S"""
      #import "components/money.typ": money
      #assert.eq(money(decimal("1234567.891")), "$1,234,567.89")
      #assert.eq(money(decimal("-1234.5")), "−$1,234.50")
      #assert.eq(money(decimal("999.995")), "$1,000.00")
      #assert.eq(money(0), "$0.00")
      #assert.eq(money(12), "$12.00")
      #assert.eq(money(0.1), "$0.10")
      #assert.eq(money(decimal("100.5"), cents: false), "$101")
      #assert.eq(money(decimal("-0.004")), "$0.00")
      #assert.eq(money(5, symbol: "€"), "€5.00")
      """)
    end
  end

  describe "charts" do
    test "pass data to JavaScript as JSON's types" do
      assert_typst([Components.Charts], ~S"""
      #import "components/charts.typ": plain
      #assert.eq(
        plain((amount: decimal("1.25"), on: datetime(year: 2026, month: 3, day: 9), note: none, rows: ((n: decimal("2")),))),
        (amount: 1.25, on: "2026-03-09", rows: ((n: 2.0),)),
      )
      """)
    end
  end

  defp assert_typst(components, source) do
    assert {:ok, _svgs} = Typsty.to_svg(source, %{}, components: components)
  end
end
