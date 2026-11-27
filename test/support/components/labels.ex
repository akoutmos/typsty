# Two components with the same name, and different files, which renders running at the same
# time must not mix up
defmodule Typsty.Test.LabelA do
  @moduledoc false
  use Typsty.Component, name: "label", files: "sources/label_a"
  def render, do: ~TYPST|#let label = read("label/label.txt")|
end

defmodule Typsty.Test.LabelB do
  @moduledoc false
  use Typsty.Component, name: "label", files: "sources/label_b"
  def render, do: ~TYPST|#let label = read("label/label.txt")|
end
