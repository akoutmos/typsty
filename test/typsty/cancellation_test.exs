defmodule Typsty.CancellationTest do
  # These tests look at the number of renders running in the whole VM, and change the
  # :max_concurrent_renders config, so they run on their own
  use ExUnit.Case, async: false

  alias Typsty.RenderError

  setup do
    # Renders from other tests that timed out may still be winding down
    wait_until_idle()
    on_exit(fn -> Application.delete_env(:typsty, :max_concurrent_renders) end)
  end

  defp wait_until_idle(timeout \\ 10_000) do
    wait_until_idle_by(System.monotonic_time(:millisecond) + timeout)
  end

  defp wait_until_idle_by(deadline) do
    running = Typsty.running_renders()

    if running == 0 or System.monotonic_time(:millisecond) > deadline do
      running
    else
      Process.sleep(10)
      wait_until_idle_by(deadline)
    end
  end

  # Laid out page by page, so a cancelled render stops quickly. Unique, so that Typst
  # can't reuse an earlier render from its cache.
  defp long_document do
    id = System.unique_integer([:positive])
    Enum.map_join(1..2000, "\n#pagebreak()\n", fn page -> "= Document #{id}, page #{page}\n#lorem(300)" end)
  end

  test "a render that times out is cancelled, and stops shortly after" do
    {micros, result} = :timer.tc(fn -> Typsty.to_pdf(long_document(), %{}, timeout: 50) end)

    assert {:error, %RenderError{reason: :timeout, diagnostics: [%{message: message}]}} = result
    assert message == "rendering didn't finish within the timeout (50 ms), and is being cancelled"
    assert micros < 1_000_000

    # The render's work stops too, rather than running to the end in the background
    assert wait_until_idle(2_000) == 0
  end

  # Here, with no other renders running, so that it can't wait for a slot past its timeout
  test "a render doing pure computation returns an error at its timeout, and finishes in the background" do
    # Typst can't cancel pure computation until it ends, which takes a second or more
    slow = "#let n = 0\n#for i in range(20000000) { n += 1 }\n#n // #{System.unique_integer()}"

    assert {:error, %RenderError{reason: :timeout, diagnostics: [%{message: message}]}} =
             Typsty.to_pdf(slow, %{}, timeout: 50)

    assert message == "rendering didn't finish within the timeout (50 ms), and is being cancelled"
    assert Typsty.running_renders() == 1

    assert {:ok, _pdf} = Typsty.to_pdf("still works", %{}, timeout: :infinity)
    assert wait_until_idle() == 0
  end

  test "PNG exports are cancelled between pages" do
    assert {:error, %RenderError{}} = Typsty.to_png(long_document(), %{}, timeout: 50)
    assert wait_until_idle(2_000) == 0
  end

  test "renders wait for a slot, and time out if none frees up in time" do
    Application.put_env(:typsty, :max_concurrent_renders, 1)

    # Pure computation can't be cancelled until it ends, so this keeps the only slot busy
    # for a while after it times out
    busy = "#let n = 0\n#for i in range(15000000) { n += 1 }\n#n // #{System.unique_integer()}"
    assert {:error, %RenderError{}} = Typsty.to_pdf(busy, %{}, timeout: 20)
    assert Typsty.running_renders() == 1

    assert {:error, %RenderError{reason: :busy, diagnostics: [%{message: message}]}} =
             Typsty.to_pdf("waits", %{}, timeout: 50)

    assert message =~ "rendering didn't start within the timeout (50 ms): 1 render was already running"

    # A render that can wait long enough gets the slot once it's free
    assert {:ok, _pdf} = Typsty.to_pdf("waits long enough", %{}, timeout: 30_000)
    assert wait_until_idle() == 0
  end

  test "a render is cancelled when the process waiting for it exits" do
    caller = spawn(fn -> Typsty.to_pdf(long_document(), %{}, timeout: :infinity) end)
    assert wait_until(fn -> Typsty.running_renders() == 1 end)

    Process.exit(caller, :kill)
    assert wait_until_idle(2_000) == 0
  end

  test "renders don't hold the VM's dirty schedulers while Typst works" do
    schedulers = :erlang.system_info(:dirty_cpu_schedulers)
    Application.put_env(:typsty, :max_concurrent_renders, schedulers * 2)

    # More renders than there are dirty CPU schedulers, all running at once
    renders =
      for _ <- 1..(schedulers * 2), do: Task.async(fn -> Typsty.to_pdf(long_document(), %{}, timeout: 10_000) end)

    assert wait_until(fn -> Typsty.running_renders() == schedulers * 2 end)

    # Checking syntax runs on a dirty CPU scheduler, which is free
    {micros, :ok} = :timer.tc(fn -> Typsty.validate("= Hello") end)
    assert micros < 500_000

    Enum.each(renders, &Task.shutdown(&1, :brutal_kill))
    assert wait_until_idle() == 0
  end

  defp wait_until(fun, tries \\ 500) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(10) && wait_until(fun, tries - 1)
    end
  end

  test "the limit must be a positive integer" do
    Application.put_env(:typsty, :max_concurrent_renders, 0)

    message =
      "invalid value for :max_concurrent_renders option: expected a positive integer of at most 10000, got: 0 " <>
        "(in the :typsty application config)"

    assert_raise ArgumentError, message, fn -> Typsty.to_pdf("x") end
  end

  # Here rather than with the other option tests, since they change the config, which this
  # module's tests run on their own for
  test "a pool starts while the config is invalid, and its renders say what's wrong" do
    # The pool's workers load their fonts with the options renders get by default, which
    # come from the config: they start without doing that, and renders report the config
    Application.put_env(:typsty, :ppi, 0)
    on_exit(fn -> Application.delete_env(:typsty, :ppi) end)
    pool = start_supervised!({Typsty.Pool, size: 1})

    assert_raise ArgumentError, ~r/invalid value for :ppi option: .* \(in the :typsty application config\)/, fn ->
      Typsty.to_pdf("x", %{}, pool: pool)
    end

    Application.delete_env(:typsty, :ppi)
    assert {:ok, "%PDF-" <> _} = Typsty.to_pdf("x", %{}, pool: pool)
  end

  test "the config is checked too, catching typos, but not other modules' config" do
    Application.put_env(:typsty, :font_path, ["fonts"])
    on_exit(fn -> Application.delete_env(:typsty, :font_path) end)

    assert_raise ArgumentError, ~r/^unknown options \[:font_path\], .* \(in the :typsty application config\)$/, fn ->
      Typsty.to_pdf("x")
    end

    Application.delete_env(:typsty, :font_path)

    # Rustler reads config :typsty, Typsty.Native; other modules' config would be a mistake
    Application.put_env(:typsty, Typsty.Native, skip_compilation?: true)
    on_exit(fn -> Application.delete_env(:typsty, Typsty.Native) end)
    assert {:ok, _pdf} = Typsty.to_pdf("x")

    Application.put_env(:typsty, Typsty.Pool, size: 2)
    on_exit(fn -> Application.delete_env(:typsty, Typsty.Pool) end)

    assert_raise ArgumentError,
                 ~r/config :typsty, Typsty.Pool isn't read: .* a Typsty.Pool's options go in its child spec/,
                 fn ->
                   Typsty.to_pdf("x")
                 end

    Application.delete_env(:typsty, Typsty.Pool)
    Application.put_env(:typsty, :files, %{"a.txt" => "a"})
    on_exit(fn -> Application.delete_env(:typsty, :files) end)

    assert_raise ArgumentError, "the :files option can't be set in the config, only given to a render", fn ->
      Typsty.to_pdf("x")
    end

    Application.delete_env(:typsty, :files)
    Application.put_env(:typsty, :components, [Typsty.Test.Brand])
    on_exit(fn -> Application.delete_env(:typsty, :components) end)

    assert_raise ArgumentError, "the :components option can't be set in the config, only given to a render", fn ->
      Typsty.to_pdf("x")
    end

    Application.delete_env(:typsty, :components)

    # Options given to a render override the config
    Application.put_env(:typsty, :ppi, 72)
    on_exit(fn -> Application.delete_env(:typsty, :ppi) end)
    assert {:ok, [small]} = Typsty.to_png("#set page(width: 1in, height: 1in)")
    assert {:ok, [large]} = Typsty.to_png("#set page(width: 1in, height: 1in)", %{}, ppi: 144)
    assert byte_size(large) > byte_size(small)
  end
end
