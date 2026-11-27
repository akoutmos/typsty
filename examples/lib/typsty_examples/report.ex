defmodule TypstyExamples.Report do
  @moduledoc """
  A quarterly business report: a cover, a table of contents, headline figures, charts and a
  table, with placeholder text. The template is in `report.typ`, next to this file, and
  draws its charts with `TypstyExamples.Components.Charts`.

  Its assigns:

  - `:company`, `:title`, `:period` (such as "Q3 2026"), `:prepared_for`, `:prepared_by`
    and `:published_on`
  - `:kpis` - headline figures: maps with a `:label`, a `:value` (as it's shown, such as
    "$2.41M") and a `:change` from the previous period (0.124 for 12.4%)
  - `:monthly_revenue` - maps with a `:month` and its `:revenue`
  - `:accounts` - maps with a `:month`, a `:plan` and its number of `:accounts`
  - `:plans` - the names of the plans, in the order the chart's legend lists them
  - `:regions` - maps with a `:region`, its `:revenue` and its `:growth` (0.08 for 8%)
  """
  use Typsty,
    components: [
      TypstyExamples.Components.Brand,
      TypstyExamples.Components.Charts,
      TypstyExamples.Components.Money
    ]
end
