defmodule TypstyExamples.ShippingLabel do
  @moduledoc """
  4 × 6 inch shipping labels for a thermal printer, one per package: addresses, a Data
  Matrix code for sorting machines, and a Code 128 barcode of the tracking number. The
  template is in `shipping_label.typ`, next to this file.

  Its assigns:

  - `:from` and `:to` - maps with a `:name` and an `:address` (a list of lines)
  - `:service` - such as "GROUND", and the `:carrier`'s name
  - `:order` - the order's number, and `:shipped_on`
  - `:packages` - maps with a `:tracking` number, a `:weight` in pounds, a `:routing` code
    and the shipper's `:reference`
  """
  use Typsty
end
