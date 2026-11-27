defmodule Typsty.Test.Icons do
  @moduledoc false
  # Its files are in another folder, and it has another name, which its paths start with
  use Typsty.Component, name: "icon-set", files: "sources/icons"

  def render do
    ~TYPST"""
    #let check(size: 1em) = box(image("icon-set/check.svg", height: size))
    #let icon(name) = box(image("icon-set/" + name + ".svg", height: 1em))
    """
  end
end
