defmodule TypstyExamples.Components.Money do
  @moduledoc """
  Formats amounts of money. A component can be written with the `~TYPST` sigil, like this
  one, rather than in a `.typ` file.
  """
  use Typsty.Component

  def render do
    ~TYPST"""
    // An amount (a decimal, an integer or a float) rounded to cents, with its thousands
    // separated: money(decimal("-1234.5")) is −$1,234.50. With cents: false, it's rounded to
    // the dollar: −$1,235
    #let money(amount, symbol: "$", cents: true) = {
      let amount = calc.round(decimal(amount), digits: if cents { 2 } else { 0 })
      let (whole, ..fraction) = str(calc.abs(amount)).split(".")
      let fraction = if cents { "." + (fraction.at(0, default: "") + "00").slice(0, 2) } else { "" }
      let digits = whole.clusters()
      let grouped = digits
        .enumerate()
        .map(((i, digit)) => if i > 0 and calc.rem(digits.len() - i, 3) == 0 { "," + digit } else { digit })
        .join()
      (if amount < 0 { "−" } else { "" }) + symbol + grouped + fraction
    }
    """
  end
end
