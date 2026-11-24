defmodule Typsty.PoolTest do
  use ExUnit.Case, async: true

  alias Typsty.{Pool, RenderError}
  alias Typsty.Test.{Greeting, Invoice}

  @moduletag :pool

  # Pure computation, which the NIF can't stop until it finishes
  @busy "#let n = 0\n#for i in range(8000) { for j in range(8000) { n += 1 } }\n#n"

  setup context do
    pool = Module.concat(__MODULE__, "Pool#{System.unique_integer([:positive])}")
    opts = Keyword.merge([name: pool, size: 2], context[:pool_opts] || [])
    start_supervised!({Pool, opts})
    %{pool: pool}
  end

  # Raw results, before Typsty turns them into {:ok, _} and RenderErrors
  defp native(source, assigns, files, options) do
    reference = make_ref()

    case Typsty.Native.start_render(reference, source, assigns, files, options) do
      {:ok, _job} ->
        receive do
          {^reference, result} -> result
        end

      error ->
        error
    end
  end

  defp pooled(pool, source, assigns, files, options),
    do: Pool.__render__(GenServer.whereis(pool), source, assigns, files, options)

  defp options(format, overrides \\ %{}) do
    Map.merge(
      %{
        format: format,
        root: nil,
        package_paths: [],
        fonts: %{font_paths: [], system_fonts: true, embedded_fonts: true},
        ppi: 72.0,
        pdf_standards: [],
        timeout: 60_000,
        max_running: 4
      },
      overrides
    )
  end

  # Waits until the pool has no idle workers. NimblePool keeps them in a queue.
  defp wait_until_busy(pool, tries \\ 500) do
    idle = :queue.len(:sys.get_state(pool).resources)

    cond do
      idle == 0 -> :ok
      tries == 0 -> flunk("the pool's workers never got busy")
      true -> Process.sleep(10) && wait_until_busy(pool, tries - 1)
    end
  end

  describe "rendering" do
    test "returns exactly what the NIF returns", %{pool: pool} do
      # A 1x1 transparent PNG
      png =
        Base.decode64!("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=")

      # Maps of more than 32 keys are stored differently by the VM, and come out of the NIF
      # and the external term format in different orders
      large_map = Map.new(1..40, &{"k#{&1}", &1})

      cases = [
        {"#set document(date: none)\n= Hello #assigns.name\n#for (k, v) in assigns.d [#k=#v ]",
         %{"name" => "World", "d" => %{"b" => 2, "a" => 1, "c" => [3, 4.5, nil, true]}}, []},
        {"#set document(date: none)\n#assigns.d.keys().join(\",\")", %{"d" => large_map}, []},
        {"#set document(date: none)\n#set text(font: \"No Such Font\")\n#assigns.d.display() #assigns.t #assigns.dt #assigns.x",
         Typsty.Value.assigns(%{
           d: ~D[2026-11-24],
           t: ~T[10:11:12],
           dt: ~N[2026-11-24 10:11:12],
           x: Decimal.new("-12.50")
         }), []},
        {"#set document(date: none)\n#assigns.n #assigns.m #assigns.a #assigns.l.len()",
         %{
           "n" => 9_223_372_036_854_775_807,
           "m" => -9_223_372_036_854_775_808,
           "a" => "é",
           "l" => Enum.to_list(1..70_000)
         }, []},
        {~s|#set document(date: none)\n#read("a.typ") #image("i.png", width: 1cm)|, %{},
         [{"a.typ", "text"}, {"i.png", png}]},
        {"line 1\n#nobody\n#import \"lib.typ\": f\n#f()", %{}, [{"lib.typ", "#let f() = missing"}]},
        {"#for i in range(10001) { context read(str(i)) }", %{}, []},
        {"#assigns.at(\"bad name\")", %{"bad name" => 1}, []},
        {"x", %{"bad" => "\xFF"}, []},
        {"x", %{"v" => {:decimal, "1E+40"}}, []},
        {"x", %{}, [{"../x", "x"}]}
      ]

      for {source, assigns, files} <- cases, format <- [:pdf, :png, :svg] do
        assert pooled(pool, source, assigns, files, options(format)) ==
                 native(source, assigns, files, options(format)),
               "#{format} render of #{inspect(source)} differs"
      end
    end

    test "document modules render the same, with errors pointing at their lines", %{pool: pool} do
      assigns = %{name: "World", items: ["one", "two"]}
      assert {:ok, "%PDF-" <> _} = Greeting.to_pdf(assigns, pool: pool)
      assert Greeting.to_svg(assigns, pool: pool) == Greeting.to_svg(assigns)

      assert {:error, %RenderError{reason: :typst, diagnostics: [diagnostic]}} =
               Greeting.to_pdf(%{name: "World", items: 1}, pool: pool)

      assert {diagnostic.file, diagnostic.line, diagnostic.column} == {"test/support/documents/greeting.ex", 12, 18}

      items = [%{name: "Widget", price: Decimal.new("19.99")}]
      assert {:ok, [_png]} = Invoice.to_png(%{number: 7, items: items}, pool: pool)
    end

    test "invalid assigns raise, as they do without a pool", %{pool: pool} do
      assert_raise ArgumentError, ~r/^assigns.v is a binary that isn't valid UTF-8/, fn ->
        Typsty.to_pdf("x", %{v: <<0xFF>>}, pool: pool)
      end

      assert_raise ArgumentError, ~r/doesn't fit in a Typst decimal/, fn ->
        Typsty.to_pdf("x", %{v: Decimal.new("1E+35")}, pool: pool)
      end
    end

    test "documents can read PDF files, which renders inside the VM refuse", %{pool: pool} do
      {:ok, pdf} = Typsty.to_pdf("#set page(width: 2cm, height: 2cm)\nA PDF")

      source = ~S|#image("page.pdf", width: 1cm)|
      assert {:ok, "%PDF-" <> _} = Typsty.to_pdf(source, %{}, files: %{"page.pdf" => pdf}, pool: pool)
      assert {:error, %RenderError{reason: :typst}} = Typsty.to_pdf(source, %{}, files: %{"page.pdf" => pdf})
    end

    test "concurrent renders sharing names don't affect each other", %{pool: pool} do
      render = fn id, pool ->
        files = %{"lib.typ" => ~s(#let tag = "lib-#{id}"), "data.json" => JSON.encode!(%{id: id})}
        source = ~s|#import "lib.typ": tag\n#assert.eq(json("data.json").id, assigns.id)\n= #tag #assigns.name|
        Typsty.to_svg(source, %{id: id, name: "Name #{id}"}, files: files, pool: pool)
      end

      expected = Map.new(1..60, &{&1, render.(&1, nil)})

      for(_ <- 1..3, id <- Enum.shuffle(1..60), do: id)
      |> Task.async_stream(&{&1, render.(&1, pool)}, max_concurrency: 16, ordered: false, timeout: :infinity)
      |> Enum.each(fn {:ok, {id, result}} -> assert result == expected[id] end)
    end

    test "callers that trap exits get no stray messages", %{pool: pool} do
      Process.flag(:trap_exit, true)

      assert {:ok, _pdf} = Typsty.to_pdf("fine", %{}, pool: pool)
      assert {:error, %RenderError{reason: :typst}} = Typsty.to_pdf("#nobody", %{}, pool: pool)
      assert {:error, %RenderError{reason: :timeout}} = Typsty.to_pdf(@busy, %{}, pool: pool, timeout: 50)

      refute_receive _message, 100
    end
  end

  describe "stopping renders" do
    test "a render that times out is stopped right away", %{pool: pool} do
      {micros, result} = :timer.tc(fn -> Typsty.to_pdf(@busy, %{}, pool: pool, timeout: 100) end)

      assert {:error, %RenderError{reason: :timeout, diagnostics: [%{message: message}]}} = result
      assert message == "rendering didn't finish within the timeout (100 ms), and its worker was stopped"
      assert micros < 1_000_000

      assert {:ok, _pdf} = Typsty.to_pdf("the pool still works", %{}, pool: pool)
    end

    @tag pool_opts: [memory_limit: 300_000_000]
    test "a render that goes over the memory limit is stopped", %{pool: pool} do
      result = Typsty.to_pdf("#let a = range(50000000)\n#a.len()", %{}, pool: pool)

      assert {:error, %RenderError{reason: :memory_limit, diagnostics: [%{message: message}]}} = result
      assert message == "the render used more than the pool's memory limit (300000000 bytes), and was stopped"

      # Typst's Roman numerals of huge numbers never finish allocating
      roman = "#counter(\"x\").update(9223372036854775807)#context counter(\"x\").display(\"I\")"
      assert {:error, %RenderError{reason: :memory_limit}} = Typsty.to_pdf(roman, %{}, pool: pool)

      # So does a string repeated enough times, which would end the VM
      huge = ~S|#let s = "a" * 4611686018427387904|
      assert {:error, %RenderError{reason: :memory_limit}} = Typsty.to_pdf(huge, %{}, pool: pool)

      assert {:ok, _pdf} = Typsty.to_pdf("the pool still works", %{}, pool: pool)
    end

    @tag pool_opts: [size: 1]
    test "a render waits for a free worker, within its timeout", %{pool: pool} do
      busy = Task.async(fn -> Typsty.to_pdf(@busy, %{}, pool: pool, timeout: 2_000) end)
      wait_until_busy(pool)

      assert {:error, %RenderError{reason: :busy, diagnostics: [%{message: message}]}} =
               Typsty.to_pdf("waits", %{}, pool: pool, timeout: 100)

      assert message == "rendering didn't start within the timeout (100 ms): every worker in the pool was busy"

      Task.await(busy)
      assert {:ok, _pdf} = Typsty.to_pdf("gets a worker", %{}, pool: pool)
    end

    @tag pool_opts: [size: 1]
    test "a pool that stops during a render ends it, but not the process waiting for it", %{pool: pool} do
      Process.flag(:trap_exit, true)
      parent = self()

      render =
        spawn(fn -> send(parent, {:result, Typsty.to_pdf(@busy, %{}, pool: pool, timeout: :infinity)}) end)

      wait_until_busy(pool)
      stop_supervised!(pool)

      assert_receive {:result, {:error, %RenderError{reason: :crashed, diagnostics: [%{message: message}]}}}, 5_000
      assert message == "the pool stopped during the render"
      refute Process.alive?(render)
      refute_received {:EXIT, _, _}
    end
  end

  test "invalid options raise" do
    assert_raise ArgumentError, "invalid value for :size option: expected positive integer, got: 0", fn ->
      Pool.start_link(size: 0)
    end

    assert_raise ArgumentError,
                 "invalid value for :memory_limit option: expected a positive integer or nil, got: -1",
                 fn ->
                   Pool.start_link(memory_limit: -1)
                 end

    assert_raise ArgumentError, ~r/^unknown options \[:workers\], valid options are: \[:name, :size/, fn ->
      Pool.start_link(workers: 2)
    end

    assert_raise ArgumentError, ~r/^invalid value for :name option: expected an atom, {:global, term}/, fn ->
      Pool.start_link(name: "pool")
    end

    assert_raise ArgumentError, ~r/invalid value for :pool option: expected the name or pid of a Typsty.Pool/, fn ->
      Typsty.to_pdf("x", %{}, pool: "pool")
    end
  end

  test "a pool whose workers can't start fails to start" do
    assert_raise ArgumentError, ~r/the :memory_limit option \(1000 bytes\) is too low for a worker to start/, fn ->
      Pool.start_link(memory_limit: 1_000)
    end
  end
end
