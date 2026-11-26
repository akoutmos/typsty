defmodule Typsty.Test.Greeting do
  @moduledoc false
  use Typsty

  def render(assigns) do
    assigns = Map.put(assigns, :shout, String.upcase(assigns.name))

    ~TYPST"""
    = Hello #assigns.name

    #assert.eq(assigns.shout, upper(assigns.name))
    #for item in assigns.items [
      - #item
    ]
    """
  end
end
