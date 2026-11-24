defmodule Typsty.Diagnostic do
  @moduledoc """
  An error or warning reported by Typst.

  - `:file` - the file the problem is in. For a problem in the template itself, it's the
    template's file (the module's `.ex` file for the `~TYPST` sigil, or its `.typ` file), or
    `nil` for a template rendered from a string. For other files, it's their path in the
    project (`/components.typ`), or `@namespace/name:version/path` for a file in a package.
  - `:line` and `:column` - where the problem is, both starting at 1, or `nil` when it has
    no location. For the template itself, they point into the template's file: the line of
    a `~TYPST` sigil in the module, for example.
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
  # the template's source. This points them at the template's file.
  @spec locate(t() | trace_point(), Typsty.Template.t()) :: t() | trace_point()
  def locate(%{file: nil, line: line, column: column} = diagnostic, %Typsty.Template{} = template)
      when is_integer(line) do
    diagnostic = %{
      diagnostic
      | file: template.file && Path.relative_to_cwd(template.file),
        line: template.line + line - 1
    }

    # The template's first line starts at its column (after `~TYPST"`, for a sigil on one
    # line), and the others at its indentation (for a heredoc)
    column = if line == 1, do: column + template.column - 1, else: column + template.indentation
    diagnostic = %{diagnostic | column: column}

    locate_trace(diagnostic, template)
  end

  def locate(%{file: nil} = diagnostic, %Typsty.Template{} = template) do
    locate_trace(%{diagnostic | file: template.file && Path.relative_to_cwd(template.file)}, template)
  end

  def locate(diagnostic, template), do: locate_trace(diagnostic, template)

  defp locate_trace(%__MODULE__{trace: trace} = diagnostic, template) do
    %{diagnostic | trace: Enum.map(trace, &locate(&1, template))}
  end

  defp locate_trace(trace_point, _template), do: trace_point

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
