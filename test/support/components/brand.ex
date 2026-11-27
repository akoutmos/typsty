defmodule Typsty.Test.Brand do
  @moduledoc false
  use Typsty.Component

  def render do
    ~TYPST"""
    // The brand's colors and name
    #let blue = rgb("#1a4d8f")
    #let name = "Acme"
    """
  end
end
