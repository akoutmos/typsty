defmodule Typsty.Diagnostic do
  @moduledoc """
  An error or warning reported by Typst.

  - `:severity` - `:error` or `:warning`.
  - `:message` - what the problem is.
  - `:file` - the file the problem is in. For a problem in the template itself, it's the
    template's file (the module's `.ex` file for the `~TYPST` sigil, or its `.typ` file), or
    `nil` for a template rendered from a string. For a problem in a component (see
    `Typsty.Component`), it's the component's file, in the same way. For other files, it's
    their path in the project (`/styles.typ`), or `@namespace/name:version/path` for a file
    in a package.
  - `:line` and `:column` - where the problem is, both starting at 1, or `nil` when it has
    no location. For the template itself and for components, they point into their file:
    the line of a `~TYPST` sigil in the module, for example.
  - `:hints` - suggestions from Typst to fix the problem.
  - `:trace` - for a problem in a function or a file called from elsewhere, the calls that
    led to it, as maps with the `:message`, `:file`, `:line` and `:column` keys.
  """

  defstruct severity: :error, message: nil, hints: [], file: nil, line: nil, column: nil, trace: []

  @type trace_point :: %{
          message: String.t(),
          file: String.t() | nil,
          line: pos_integer() | nil,
          column: pos_integer() | nil
        }

  @type t :: %__MODULE__{
          severity: :error | :warning,
          message: String.t(),
          hints: [String.t()],
          file: String.t() | nil,
          line: pos_integer() | nil,
          column: pos_integer() | nil,
          trace: [trace_point()]
        }

  @doc false
  # Diagnostics from the native code have no file for the template itself, and positions in
  # the template's source. This points them at the template's file. Diagnostics in a
  # component (`/components/tables.typ`, in `components`) point at the component's file.
  @spec locate(t() | trace_point(), Typsty.Template.t(), %{String.t() => Typsty.Template.t()}) ::
          t() | trace_point()
  def locate(diagnostic, template, components \\ %{})

  def locate(%{file: nil} = diagnostic, %Typsty.Template{} = template, components) do
    diagnostic |> position(template) |> locate_trace(template, components)
  end

  def locate(%{file: file} = diagnostic, template, components) when is_map_key(components, file) do
    diagnostic |> position(Map.fetch!(components, file)) |> locate_trace(template, components)
  end

  def locate(diagnostic, template, components), do: locate_trace(diagnostic, template, components)

  # A position in a template's source, as one in its file
  defp position(%{line: line, column: column} = diagnostic, %Typsty.Template{} = template) when is_integer(line) do
    diagnostic = %{diagnostic | file: file(diagnostic, template), line: template.line + line - 1}

    # The template's first line starts at its column (after `~TYPST"`, for a sigil on one
    # line), and the others at its indentation (for a heredoc). They're unknown when the
    # formatter reports an error
    column =
      cond do
        is_nil(column) -> nil
        line == 1 and is_integer(template.column) -> column + template.column - 1
        line > 1 and is_integer(template.indentation) -> column + template.indentation
        true -> nil
      end

    %{diagnostic | column: column}
  end

  defp position(diagnostic, template), do: %{diagnostic | file: file(diagnostic, template)}

  # A template built from a string has no file: its diagnostics keep the one they have (none
  # for the template itself, its path in the project for a component)
  defp file(diagnostic, %Typsty.Template{file: nil}), do: diagnostic.file
  defp file(_diagnostic, %Typsty.Template{file: file}), do: Path.relative_to_cwd(file)

  defp locate_trace(%__MODULE__{trace: trace} = diagnostic, template, components) do
    %{diagnostic | trace: Enum.map(trace, &locate(&1, template, components))}
  end

  defp locate_trace(trace_point, _template, _components), do: trace_point

  @doc """
  Formats the diagnostic as a message, like `lib/invoice.ex:12:5: unknown variable: total`,
  followed by its hints and trace.
  """
  @spec format(t()) :: String.t()
  def format(%__MODULE__{} = diagnostic) do
    severity = if diagnostic.severity == :warning, do: "warning: ", else: ""

    lines =
      [location(diagnostic) <> severity <> diagnostic.message] ++
        Enum.map(diagnostic.hints, &("  hint: " <> &1)) ++
        Enum.map(diagnostic.trace, &("  " <> location(&1) <> &1.message))

    Enum.join(lines, "\n")
  end

  defp location(%{file: file, line: line, column: column}) do
    [file, line, column]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> ""
      parts -> Enum.join(parts, ":") <> ": "
    end
  end
end
