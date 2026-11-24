defmodule Typsty.Formatter do
  @moduledoc """
  A `mix format` [plugin](https://hexdocs.pm/mix/Mix.Tasks.Format.html#module-plugins) that
  formats `~TYPST` sigils and `.typ` files with
  [typstyle](https://github.com/typstyle-rs/typstyle).

  ## Setup

  Add it as a plugin to your `.formatter.exs`, and include the `.typ` extension in `inputs`
  to format templates that are next to their modules:

  ```elixir
  [
    plugins: [Typsty.Formatter],
    inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs,typ}"]
  ]
  ```

  ## Options

  These options go in `.formatter.exs` too:

  - `:typst_line_length` - the maximum line length for templates. Defaults to the
    formatter's `:line_length`, or 98.
  - `:typst_indent` - the number of spaces to indent by. Defaults to 2.
  - `:typst_wrap_text` - whether to wrap long lines of text in markup. Defaults to `false`.

  The line length applies to the template itself: lines in a `~TYPST` heredoc are also
  indented by the Elixir code around them.

  To leave a sigil as it is, use the `noformat` modifier: `~TYPST\"\"\"...\"\"\"noformat`.

  A template with syntax errors can't be formatted, so formatting it raises
  `Typsty.SyntaxError`, the way `mix format` fails on invalid Elixir code.
  """

  @behaviour Mix.Tasks.Format

  @default_line_length 98

  @heredoc_delimiters [~s("""), ~s(''')]

  @impl Mix.Tasks.Format
  def features(_opts) do
    [sigils: [:TYPST], extensions: [".typ"]]
  end

  @impl Mix.Tasks.Format
  def format(source, opts) do
    if opts[:sigil] == :TYPST and opts[:modifiers] == ~c"noformat" do
      source
    else
      do_format(source, opts)
    end
  end

  defp do_format(source, opts) do
    format_opts = [
      line_length: opts[:typst_line_length] || opts[:line_length] || @default_line_length,
      indent: opts[:typst_indent] || 2,
      wrap_text: Keyword.get(opts, :typst_wrap_text, false)
    ]

    case Typsty.format(source, format_opts) do
      {:ok, formatted} ->
        layout(formatted, source, opts)

      {:error, diagnostics} ->
        Typsty.SyntaxError.raise!(diagnostics, template(source, opts))
    end
  end

  defp layout(formatted, source, opts) do
    cond do
      # A .typ file keeps typstyle's output, which ends with a newline
      not Keyword.has_key?(opts, :sigil) -> formatted
      # A heredoc's content ends with a newline, so its closing delimiter is on its own line
      opts[:opening_delimiter] in @heredoc_delimiters -> heredoc(formatted)
      true -> single_line(formatted, source, opts[:opening_delimiter])
    end
  end

  defp heredoc(formatted) do
    case String.trim_trailing(formatted) do
      "" -> ""
      formatted -> formatted <> "\n"
    end
  end

  # A sigil on one line, like ~TYPST"*#name*", stays on one line, and is left as it is when
  # formatting would add its closing delimiter, which would have to be escaped
  defp single_line(formatted, source, opening_delimiter) do
    formatted = String.trim_trailing(formatted, "\n")
    closing = closing_delimiter(opening_delimiter)

    cond do
      String.contains?(formatted, "\n") and not String.contains?(source, "\n") -> source
      closing && count(formatted, closing) > count(source, closing) -> source
      true -> formatted
    end
  end

  defp closing_delimiter(opening) do
    Map.get(
      %{"\"" => "\"", "'" => "'", "(" => ")", "[" => "]", "{" => "}", "<" => ">", "|" => "|", "/" => "/"},
      opening
    )
  end

  defp count(text, pattern), do: length(:binary.matches(text, pattern))

  # The template's position, to point syntax errors at the file being formatted
  defp template(source, opts) do
    line = opts[:line] || 1
    line = if opts[:opening_delimiter] in @heredoc_delimiters, do: line + 1, else: line

    %Typsty.Template{source: source, file: opts[:file], line: line}
  end
end
