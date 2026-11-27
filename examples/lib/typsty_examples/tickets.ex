defmodule TypstyExamples.Tickets do
  @moduledoc """
  Tickets for an event, one per page, each with a QR code to scan at the door. The template
  is in `tickets.typ`, next to this file.

  Its assigns:

  - `:event` - a map with a `:name`, a `:tagline`, a `:venue`, its `:address`, and when it
    `:starts_at` and `:ends_at` (`NaiveDateTime`s, in the venue's time)
  - `:order` - a map with its `:number` and the `:email` it was sent to
  - `:tickets` - maps with the `:holder`'s name, the ticket's `:type`, what it `:admits` to,
    and its `:code`, which its QR code holds as a URL to check it
  """
  use Typsty, components: [TypstyExamples.Components.Brand]
end
