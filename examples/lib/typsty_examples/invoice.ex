defmodule TypstyExamples.Invoice do
  @moduledoc """
  An invoice, with its lines, totals, and a QR code that links to the page to pay it.

  The template is in `invoice.typ`, next to this file. It takes these assigns:

  - `:company` - the company sending it: `:name`, `:address` (a list of lines), `:email`
    and `:website`
  - `:customer` - a `TypstyExamples.Customer`
  - `:number`, `:issued_on` and `:due_on`, and optionally `:purchase_order`
  - `:status` - `:open`, `:paid` or `:overdue`
  - `:lines` - maps with a `:description`, a `:quantity` and a `:unit_price`, and
    optionally `:details`
  - `:tax_rate` - a `Decimal`, such as `Decimal.new("0.0825")`
  - `:discount` - optional: a map with a `:label` and an `:amount` off the subtotal
  - `:amount_paid` - a `Decimal`
  - `:payment_url` - where to pay it online
  - `:notes` - optional text at the end
  """
  use Typsty,
    components: [
      TypstyExamples.Components.Brand,
      TypstyExamples.Components.Letterhead,
      TypstyExamples.Components.Money
    ]
end
