defmodule TypstyExamples.Components.Letterhead do
  @moduledoc """
  Pages with Kestrel Labs' header and footer, for business documents. Its source is in
  `letterhead.typ`.

  It takes the company's details as an argument, rather than having them written in, so
  they can come from the application's config.
  """
  use Typsty.Component, components: [TypstyExamples.Components.Brand]
end
