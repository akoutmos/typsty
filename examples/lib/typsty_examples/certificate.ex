defmodule TypstyExamples.Certificate do
  @moduledoc """
  A certificate of completion for a course, with the instructor's signature and a QR code
  that links to a page that verifies it. The template is in `certificate.typ`, next to
  this file.

  The signature is an image that changes from certificate to certificate, so it's passed
  with the `:files` option, as `signature.svg`.

  Its assigns:

  - `:recipient`, `:course`, `:hours` and `:completed_on`
  - `:instructor` - a map with the `:name` and `:title` of whoever signed it
  - `:id` - the certificate's id, which its QR code links to as a URL that verifies it
  """
  use Typsty, components: [TypstyExamples.Components.Brand]
end
