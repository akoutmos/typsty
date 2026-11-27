defmodule Typsty.SyntaxError do
  @moduledoc """
  A template has invalid Typst syntax, or a component breaks the rules for components (see
  `Typsty.Component`). Raised when a module with a `~TYPST` sigil or a `.typ` template is
  compiled (or a component, with the `.typ` files in its folder), so that the problem fails
  the build instead of a render, and when `mix format` formats one with `Typsty.Formatter`.

  `:diagnostics` has every problem in the template, and `:file`, `:line` and `:column` point
  at the first one. `:kind` is `:syntax` for syntax errors, and `:component` for breaking
  the rules for components: content at their top level, reading `sys.inputs`, or reading a
  file they don't have.
  """

  defexception [:file, :line, :column, :snippet, diagnostics: [], kind: :syntax]

  @type t :: %__MODULE__{
          file: String.t() | nil,
          line: pos_integer() | nil,
          column: pos_integer() | nil,
          snippet: String.t() | nil,
          diagnostics: [Typsty.Diagnostic.t()],
          kind: :syntax | :component
        }

  @impl Exception
  def message(%__MODULE__{diagnostics: [first | _] = diagnostics, snippet: snippet} = error) do
    others =
      case diagnostics do
        [_] -> ""
        [_ | rest] -> "\n\n" <> Enum.map_join(rest, "\n\n", &Typsty.Diagnostic.format/1)
      end

    headline(error) <> ": " <> Typsty.Diagnostic.format(first) <> (snippet || "") <> others
  end

  def message(%__MODULE__{} = error), do: headline(error)

  defp headline(%__MODULE__{kind: :component}), do: "invalid component"
  defp headline(%__MODULE__{}), do: "invalid Typst syntax"

  @doc false
  # Raises for the syntax errors of a template (or what a component can't have), pointing at
  # the template's file
  @spec raise!([Typsty.Diagnostic.t()], Typsty.Template.t()) :: no_return()
  @spec raise!([Typsty.Diagnostic.t()], Typsty.Template.t(), :syntax | :component) :: no_return()
  def raise!([_ | _] = diagnostics, %Typsty.Template{} = template, kind \\ :syntax) do
    [first | _] = diagnostics = Enum.map(diagnostics, &Typsty.Diagnostic.locate(&1, template))

    raise __MODULE__,
      file: first.file,
      line: first.line,
      column: first.column,
      snippet: snippet(template, first),
      diagnostics: diagnostics,
      kind: kind
  end

  # The template's line with the error, with a caret under the column
  defp snippet(%Typsty.Template{source: source} = template, %{line: line, column: column})
       when is_integer(line) and is_integer(column) do
    source_line = source |> String.split("\n") |> Enum.at(line - template.line)

    if source_line do
      column_in_source = column - if(line == template.line, do: template.column, else: template.indentation + 1)

      "\n\n    " <> source_line <> "\n    " <> String.duplicate(" ", max(column_in_source, 0)) <> "^"
    end
  end

  defp snippet(_template, _diagnostic), do: nil
end
