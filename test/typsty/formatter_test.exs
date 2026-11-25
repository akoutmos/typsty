defmodule Typsty.FormatterTest do
  use ExUnit.Case, async: true

  alias Typsty.Formatter

  # Formats Elixir code the way `mix format` does with the plugin
  defp format_elixir(code, opts \\ []) do
    opts = [line_length: 98] ++ opts
    sigils = [TYPST: &Formatter.format(&1, &2 ++ opts)]
    code |> Code.format_string!(Keyword.put(opts, :sigils, sigils)) |> IO.iodata_to_binary()
  end

  test "claims the ~TYPST sigil and .typ files" do
    assert Formatter.features([]) == [sigils: [:TYPST], extensions: [".typ"]]
  end

  test "formats .typ files" do
    assert Formatter.format("#let   x=(1,2)\n= Title", extension: ".typ") == "#let x = (1, 2)\n= Title\n"
  end

  test "formats heredoc sigils, keeping their indentation" do
    code = ~S'''
    def render(assigns) do
      ~TYPST"""
      #let   total=assigns.items.map(i=>i.price).sum()
      = Invoice #assigns.number

      #for item in assigns.items {[- #item.name]}
      """
    end
    '''

    assert format_elixir(code) ==
             String.trim_trailing(~S'''
             def render(assigns) do
               ~TYPST"""
               #let total = assigns.items.map(i => i.price).sum()
               = Invoice #assigns.number

               #for item in assigns.items { [- #item.name] }
               """
             end
             ''')
  end

  test "keeps raw blocks and the content of the template exactly" do
    code = ~S'''
    def render(assigns) do
      ~TYPST"""
      ```elixir
      def hello,   do: :world
      ```
      """
    end
    '''

    assert format_elixir(code) == String.trim_trailing(code)
  end

  test "formats single-line sigils" do
    assert format_elixir(~S|~TYPST"#let   x=1"|) == ~S|~TYPST"#let x = 1"|
  end

  test "leaves a single-line sigil alone when formatting would break it into lines" do
    code = ~S|~TYPST"#let items = (1111111111, 2222222222, 3333333333, 4444444444)"|
    assert format_elixir(code, typst_line_length: 20) == code
  end

  test "leaves sigils with the noformat modifier alone" do
    code = ~S'''
    ~TYPST"""
    #let   x=1
    """noformat
    '''

    assert format_elixir(code) == String.trim_trailing(code)
  end

  test "uses the typst options" do
    source = ~s|#let items = ("first item", "second item")|

    assert Formatter.format(source, extension: ".typ", typst_line_length: 30, typst_indent: 4) ==
             ~s|#let items = (\n    "first item",\n    "second item",\n)\n|

    # :line_length is the default
    assert Formatter.format(source, extension: ".typ", line_length: 30) ==
             ~s|#let items = (\n  "first item",\n  "second item",\n)\n|
  end

  test "raises for invalid syntax, pointing at the file" do
    error =
      assert_raise Typsty.SyntaxError, fn ->
        Formatter.format("Fine\n#let x = (1, 2\n",
          sigil: :TYPST,
          modifiers: [],
          opening_delimiter: ~s("""),
          file: "lib/doc.ex",
          line: 10
        )
      end

    # The formatter isn't told the sigil's column or indentation, so the error has no column
    assert {error.file, error.line, error.column} == {"lib/doc.ex", 12, nil}

    error =
      assert_raise Typsty.SyntaxError, fn ->
        Formatter.format("Fine\n#let x = (1, 2\n", extension: ".typ", file: "lib/doc.typ")
      end

    assert {error.file, error.line, error.column} == {"lib/doc.typ", 2, 10}
  end

  test "raises for invalid options, naming the formatter's option" do
    assert_raise ArgumentError, "invalid value for :typst_line_length option: expected positive integer, got: 0", fn ->
      Formatter.format("x", extension: ".typ", typst_line_length: 0)
    end
  end
end
