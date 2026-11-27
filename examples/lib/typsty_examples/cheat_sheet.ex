defmodule TypstyExamples.CheatSheet do
  @moduledoc """
  A one-page reference for a library or an API, in three columns: sections of short notes,
  each with a snippet of code. The template is in `cheat_sheet.typ`, next to this file, and
  works for any subject. The sample is a cheat sheet for Typsty itself.

  Its assigns:

  - `:title`, `:subtitle`, `:version` and `:url`
  - `:sections` - maps with a `:title` and `:entries`: maps with a `:note`, and optionally
    `:code` and its `:lang` (such as "elixir" or "typ", for Typst), which is highlighted
  """
  use Typsty, components: [TypstyExamples.Components.Brand]
end
