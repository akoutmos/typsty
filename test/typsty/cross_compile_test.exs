defmodule Typsty.CrossCompileTest do
  # Not async: while the NIF counts as unavailable, templates that other tests compile
  # wouldn't be checked
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  # When cross-compiling, the NIF is built for another machine, so templates compile without
  # being checked, with one warning
  @unavailable {Typsty, :native_unavailable}

  setup do
    unavailable = :persistent_term.get(@unavailable, false)
    :persistent_term.put(@unavailable, false)
    on_exit(fn -> :persistent_term.put(@unavailable, unavailable) end)
  end

  test "templates compile unchecked, with one warning, without trying the NIF again" do
    unloaded = fn _source ->
      raise UndefinedFunctionError, module: Typsty.Native, function: :syntax_errors, arity: 1
    end

    # Every try to load a NIF that can't be loaded logs the failure
    not_tried = fn _source -> flunk("the NIF was tried again") end

    warnings =
      capture_io(:stderr, fn ->
        assert Typsty.__native_check__(unloaded, "#let x = (") == :unavailable
        assert Typsty.__native_check__(not_tried, "#let x = (") == :unavailable
      end)

    assert warnings =~
             "Typsty can't check templates and components, since its NIF couldn't be loaded (cross-compiling?)"

    assert length(String.split(warnings, "can't check templates")) == 2
  end

  test "a NIF that loaded without its functions is unavailable too" do
    not_loaded = fn _source -> :erlang.nif_error(:nif_not_loaded) end

    warnings =
      capture_io(:stderr, fn ->
        assert Typsty.__native_check__(not_loaded, "#let x = (") == :unavailable
      end)

    assert warnings =~ "can't check templates"
  end

  test "other errors aren't hidden" do
    other_module = fn _source -> raise UndefinedFunctionError, module: Typsty.Elsewhere, function: :f, arity: 1 end
    other_error = fn _source -> :erlang.error(:badarg) end

    assert_raise UndefinedFunctionError, ~r/Typsty.Elsewhere.f\/1/, fn ->
      Typsty.__native_check__(other_module, "")
    end

    assert_raise ArgumentError, fn -> Typsty.__native_check__(other_error, "") end
    assert Typsty.__native_check__(&Typsty.Native.syntax_errors/1, "= Fine") == []
    refute :persistent_term.get(@unavailable, false)
  end
end
