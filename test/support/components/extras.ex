defmodule Typsty.Test.Extras do
  @moduledoc false
  use Typsty.Component

  def render do
    ~TYPST"""
    #let mono(body) = text(font: "DejaVu Sans Mono", body)
    #let site(url, body) = link(url, body)
    #let fancy(body) = text(font: "No Such Font", body)
    #let each(items, show-item) = items.map(show-item).join([, ])
    """
  end
end
