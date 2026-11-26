defmodule Typsty.Test.Tables do
  @moduledoc false
  use Typsty.Component, name: "line-items"

  def render do
    ~TYPST"""
    #let line-items(items) = table(
      columns: (1fr, auto),
      [*Item*], [*Price*],
      ..items.map(item => (item.name, [#item.price])).flatten(),
    )

    #let uses-assigns() = assigns.total
    """
  end
end
