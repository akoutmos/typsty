defmodule Typsty.Test.Statement do
  @moduledoc false
  use Typsty, components: [Typsty.Test.Letterhead, Typsty.Test.Tables]

  def render(assigns) do
    ~TYPST"""
    #import "components/letterhead.typ": letterhead, signature
    #import "components/line-items.typ": line-items
    #show: letterhead.with(title: [Statement #assigns.number])

    #line-items(assigns.items)
    #signature(assigns.signed_by)
    """
  end
end
