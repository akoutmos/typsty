defmodule Typsty.Test.Money do
  @moduledoc false
  use Typsty.Component

  def render do
    ~TYPST"""
    #let money(amount, currency: "$") = [#currency#calc.round(amount, digits: 2)]
    """
  end
end
