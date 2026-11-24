defmodule Typsty.PoolTest do
  use ExUnit.Case, async: true

  alias Typsty.{Pool, RenderError}
  alias Typsty.Test.{Greeting, Invoice}

  @moduletag :pool

  setup context do
    pool = Module.concat(__MODULE__, "Pool#{System.unique_integer([:positive])}")
    opts = Keyword.merge([name: pool, size: 2], context[:pool_opts] || [])
    start_supervised!({Pool, opts})
    %{pool: pool}
  end

  # Raw results, before Typsty turns them into {:ok, _} and RenderErrors
  defp native(source, variables, files, options), do: Typsty.Native.render(source, variables, files, options)

  defp pooled(pool, source, variables, files, options), do: Pool.__render__(pool, source, variables, files, options)

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

  describe "rendering" do
    test "returns exactly what the NIF returns", %{pool: pool} do
      # A 1x1 transparent PNG
      png =
        Base.decode64!("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=")

      cases = [
        {"#set document(date: none)\n= Hello #name\n#for (k, v) in d [#k=#v ]",
         %{"name" => "World", "d" => %{"b" => 2, "a" => 1, "c" => [3, 4.5, nil, true]}}, []},
        {"#set document(date: none)\n#set text(font: \"No Such Font\")\n#d.display() #t #dt #x",
         Typsty.Value.variables(%{
           d: ~D[2026-11-24],
           t: ~T[10:11:12],
           dt: ~N[2026-11-24 10:11:12],
           x: Decimal.new("-12.50")
         }), []},
        {~s|#set document(date: none)\n#read("a.typ") #image("i.png", width: 1cm)|, %{},
         [{"a.typ", "text"}, {"i.png", png}]},
        {"line 1\n#nobody\n#import \"lib.typ\": f\n#f()", %{}, [{"lib.typ", "#let f() = missing"}]},
        {"x", %{"bad name" => 1}, []},
        {"x", %{"v" => {:decimal, "1E+40"}}, []}
      ]

      for {source, variables, files} <- cases, format <- [:pdf, :png, :svg] do
        assert pooled(pool, source, variables, files, options(format)) ==
                 native(source, variables, files, options(format)),
               "#{format} render of #{inspect(source)} differs"
      end
    end

    test "document modules render the same, with errors pointing at their lines", %{pool: pool} do
      assigns = %{name: "World", items: ["one", "two"]}
      assert {:ok, "%PDF-" <> _} = Greeting.to_pdf(assigns, pool: pool)
      assert Greeting.to_svg(assigns, pool: pool) == Greeting.to_svg(assigns)

      assert {:error, %RenderError{diagnostics: [diagnostic]}} = Greeting.to_pdf(%{name: "World", items: 1}, pool: pool)
      assert {diagnostic.file, diagnostic.line, diagnostic.column} == {"test/support/documents/greeting.ex", 12, 18}

      items = [%{name: "Widget", price: Decimal.new("19.99")}]
      assert {:ok, [_png]} = Invoice.to_png(%{number: 7, items: items}, pool: pool)
    end

    test "invalid variables raise, as they do without a pool", %{pool: pool} do
      assert_raise ArgumentError, ~r/"bad name" is not a valid Typst variable name/, fn ->
        Typsty.to_pdf("x", %{"bad name" => 1}, pool: pool)
      end
    end

    test "the pool can be set in the config", %{pool: pool} do
      # Only this process's renders: the config is read when rendering, so it's set and
      # removed around the call
      Application.put_env(:typsty, :pool, pool)
      result = Typsty.to_svg("from the config")
      Application.delete_env(:typsty, :pool)

      assert result == Typsty.to_svg("from the config")
    end

    test "concurrent renders sharing names don't affect each other", %{pool: pool} do
      render = fn id, pool ->
        files = %{"lib.typ" => ~s(#let tag = "lib-#{id}"), "data.json" => JSON.encode!(%{id: id})}
        source = ~s|#import "lib.typ": tag\n#assert.eq(json("data.json").id, id)\n= #tag #name|
        Typsty.to_svg(source, %{id: id, name: "Name #{id}"}, files: files, pool: pool)
      end

      expected = Map.new(1..60, &{&1, render.(&1, nil)})

      for(_ <- 1..3, id <- Enum.shuffle(1..60), do: id)
      |> Task.async_stream(&{&1, render.(&1, pool)}, max_concurrency: 16, ordered: false, timeout: :infinity)
      |> Enum.each(fn {:ok, {id, result}} -> assert result == expected[id] end)
    end
  end

  describe "stopping renders" do
    # Pure computation, which the NIF can't stop until it finishes
    @busy "#let n = 0\n#for i in range(8000) { for j in range(8000) { n += 1 } }\n#n"

    test "a render that times out is stopped right away", %{pool: pool} do
      {micros, result} = :timer.tc(fn -> Typsty.to_pdf(@busy, %{}, pool: pool, timeout: 100) end)

      assert {:error, %RenderError{diagnostics: [%{message: message}]}} = result
      assert message == "rendering didn't finish within the timeout (100 ms), and was stopped"
      assert micros < 1_000_000

      assert {:ok, _pdf} = Typsty.to_pdf("the pool still works", %{}, pool: pool)
    end

    @tag pool_opts: [memory_limit: 300_000_000]
    test "a render that goes over the memory limit is stopped", %{pool: pool} do
      result = Typsty.to_pdf("#let a = range(50000000)\n#a.len()", %{}, pool: pool)

      assert {:error, %RenderError{diagnostics: [%{message: message}]}} = result
      assert message == "the render used more than the pool's memory limit (300000000 bytes), and was stopped"

      # Typst's Roman numerals of huge numbers never finish allocating
      roman = "#counter(\"x\").update(9223372036854775807)#context counter(\"x\").display(\"I\")"
      assert {:error, %RenderError{}} = Typsty.to_pdf(roman, %{}, pool: pool)

      assert {:ok, _pdf} = Typsty.to_pdf("the pool still works", %{}, pool: pool)
    end

    @tag pool_opts: [size: 1]
    test "a render waits for a free worker, within its timeout", %{pool: pool} do
      busy = Task.async(fn -> Typsty.to_pdf(@busy, %{}, pool: pool, timeout: 2_000) end)
      Process.sleep(100)

      assert {:error, %RenderError{diagnostics: [%{message: message}]}} =
               Typsty.to_pdf("waits", %{}, pool: pool, timeout: 100)

      assert message == "rendering didn't start within the timeout (100 ms): every worker in the pool was busy"

      Task.await(busy)
      assert {:ok, _pdf} = Typsty.to_pdf("gets a worker", %{}, pool: pool)
    end
  end

  test "invalid options raise" do
    assert_raise ArgumentError, ~r/:size option must be a positive integer/, fn -> Pool.start_link(size: 0) end

    assert_raise ArgumentError, ~r/:memory_limit option must be a positive integer/, fn ->
      Pool.start_link(memory_limit: -1)
    end

    assert_raise ArgumentError, ~r/:pool option must be the name or pid of a Typsty.Pool/, fn ->
      Typsty.to_pdf("x", %{}, pool: "pool")
    end
  end
end
