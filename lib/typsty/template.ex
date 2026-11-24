defmodule Typsty.Template do
  @moduledoc """
  A Typst template with the variables to render it with.

  The `~TYPST` sigil and the `render/1` of a document module return this struct. Pass it to
  `Typsty.to_pdf/3`, `Typsty.to_png/3` or `Typsty.to_svg/3` to render it.

  - `:source` - the Typst source.
  - `:assigns` - the variables to render it with.
  - `:file` - the file it's in, which errors point at, or `nil` for a template built from a
    string (its errors point at lines of the string).

  The other fields are internal: they record where the template starts in its file.
  """

  @enforce_keys [:source]
  defstruct source: nil, assigns: %{}, file: nil, line: 1, column: 1, indentation: 0

  @type t :: %__MODULE__{
          source: String.t(),
          assigns: map(),
          file: Path.t() | nil,
          line: pos_integer(),
          column: pos_integer() | nil,
          indentation: non_neg_integer() | nil
        }
end
