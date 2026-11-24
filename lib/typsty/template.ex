defmodule Typsty.Template do
  @moduledoc """
  A Typst template with the variables to render it with.

  The `~TYPST` sigil and the `render/1` of a document module return this struct. Pass it to
  `Typsty.to_pdf/3`, `Typsty.to_png/3` or `Typsty.to_svg/3` to render it.

  The template's location (`:file`, `:line`, `:column` and `:indentation`) is used to point
  errors at the line of the Elixir file (or `.typ` file) where the problem is. A template
  built from a string has no file, and its errors point at lines of the string.
  """

  @enforce_keys [:source]
  defstruct source: nil, assigns: %{}, file: nil, line: 1, column: 1, indentation: 0

  @type t :: %__MODULE__{
          source: String.t(),
          assigns: map(),
          file: Path.t() | nil,
          line: pos_integer(),
          column: pos_integer(),
          indentation: non_neg_integer()
        }
end
