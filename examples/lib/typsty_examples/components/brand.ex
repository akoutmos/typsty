defmodule TypstyExamples.Components.Brand do
  @moduledoc """
  Kestrel Labs' colors, fonts and logo, which every example shares.

  The component's source is in `brand.typ`, and its logo in `brand/logo.svg`, which
  renders get at `components/brand/logo.svg`. Documents import what they use:

  ```typst
  #import "components/brand.typ": colors, logo
  ```
  """
  use Typsty.Component
end
