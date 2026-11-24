defmodule Typsty.Test.Greeting do
  @moduledoc false
  use Typsty

  def render(assigns) do
    assigns = Map.put(assigns, :shout, String.upcase(assigns.name))

    ~TYPST"""
    = Hello #name

    #assert.eq(shout, upper(name))
    #for item in items [
      - #item
    ]
    """
  end
end
