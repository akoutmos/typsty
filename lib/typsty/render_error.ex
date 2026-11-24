defmodule Typsty.RenderError do
  @moduledoc """
  Rendering a document failed. `:diagnostics` has the errors Typst reported, as
  `Typsty.Diagnostic` structs.

  Since a template's syntax is checked when it's compiled, these are errors that depend on
  the data or the environment: a variable the template uses but that wasn't given, a value of
  the wrong type, a missing file or font, and so on.
  """

  defexception diagnostics: []

  @type t :: %__MODULE__{diagnostics: [Typsty.Diagnostic.t()]}

  @impl Exception
  def message(%__MODULE__{diagnostics: diagnostics}) do
    "failed to render the Typst document:\n\n" <> Enum.map_join(diagnostics, "\n\n", &Typsty.Diagnostic.format/1)
  end
end
