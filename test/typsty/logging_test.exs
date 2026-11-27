defmodule Typsty.LoggingTest do
  # Turns on the logging of warnings, which the other tests turn off (test_helper.exs), and
  # captures the log, so these tests run on their own
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  setup do
    Application.put_env(:typsty, :log_warnings, true)
    on_exit(fn -> Application.put_env(:typsty, :log_warnings, false) end)
  end

  test "warnings are logged" do
    log = capture_log(fn -> assert {:ok, _pdf} = Typsty.to_pdf(~s|#set text(font: "No Such Font")\nHi|) end)
    assert log =~ "[Typsty] 1:"
    assert log =~ "warning: unknown font family: no such font"
  end

  test "warnings that quote the assigns stay on one line" do
    source = "#set text(font: assigns.font)\nHi"
    log = capture_log(fn -> assert {:ok, _pdf} = Typsty.to_pdf(source, %{font: "x\n[error] forged"}) end)
    assert log =~ ~S|unknown font family: x\n[error] forged|
  end

  test "links to URLs other than web, mail and phone ones are left out with a warning" do
    log = capture_log(fn -> assert {:ok, _pdf} = Typsty.to_pdf(~S|#link("javascript:alert(1)")[x]|) end)
    assert log =~ "a link to a javascript: URL was left out of the document"
  end

  @tag :tmp_dir
  test "fonts from the font paths are used", %{tmp_dir: fonts} do
    assert Typsty.font_families(system_fonts: false, embedded_fonts: false) == []

    # A font that comes with the tests (see test/support/fonts), whatever the system has
    File.cp!(Path.expand("../support/fonts/colr_1.ttf", __DIR__), Path.join(fonts, "font.ttf"))

    assert [family | _] = Typsty.font_families(system_fonts: false, embedded_fonts: false, font_paths: [fonts])

    # Without the embedded fonts, the text can only use the font from the font path, and
    # there's no warning about a missing font
    source = "#set text(font: assigns.family)\nHello"
    opts = [system_fonts: false, embedded_fonts: false, font_paths: [fonts]]
    assert capture_log(fn -> assert {:ok, _pdf} = Typsty.to_pdf(source, %{family: family}, opts) end) == ""
  end
end
