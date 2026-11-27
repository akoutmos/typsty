defmodule Typsty.Test.Totals do
  @moduledoc false
  # The source is in totals.typ, next to this file. It imports money.typ as a sibling, and
  # brand.typ by its absolute path
  use Typsty.Component, components: [Typsty.Test.Money, Typsty.Test.Brand]
end
