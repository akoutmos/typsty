defmodule TypstyExamples.Components.Charts do
  @moduledoc """
  Charts in Kestrel Labs' colors and type, drawn with the
  [nulite](https://typst.app/universe/package/nulite) package, which renders
  [Vega-Lite](https://vega.github.io/vega-lite/) charts. Its source is in `charts.typ`.

  A component can import packages, like documents can: they're found in the directories of
  the `:package_paths` option.
  """
  use Typsty.Component, components: [TypstyExamples.Components.Brand]
end
