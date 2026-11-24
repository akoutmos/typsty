defmodule Typsty.ConcurrencyTest do
  # Renders of the same template, with the same file names and assigns names but different
  # values, as a Phoenix controller would do for each request, must not affect each other:
  # rendered concurrently, each one must produce exactly what it produces on its own.
  use ExUnit.Case, async: true

  defmodule Invoice do
    @moduledoc false
    use Typsty

    def render(assigns) do
      ~TYPST"""
      #set document(title: [Invoice], date: none)
      #set page(width: 12cm, height: auto, margin: 1cm)
      #import "lib.typ": tag

      #let data = json("data.json")
      #assert.eq(data.id, id)
      #assert.eq(tag, "lib-" + str(id))

      #image("logo.png", width: 2cm)

      = Invoice #id for #customer.name

      #table(
        columns: (1fr, auto),
        ..items.map(item => (item.name, [#item.price])).flatten(),
      )

      Total: #items.map(item => item.price).sum()
      Notes: #data.notes.join(", ")
      """
    end
  end

  # A solid-color PNG, different for each render and of a different size
  defp png(id) do
    width = 4 + rem(id, 7)
    {r, g, b} = {rem(id * 37, 256), rem(id * 91, 256), rem(id * 53, 256)}
    rows = for _ <- 1..4, into: <<>>, do: <<0>> <> :binary.copy(<<r, g, b>>, width)
    chunk = fn type, data -> <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>> end

    <<137, "PNG\r\n", 26, "\n">> <>
      chunk.("IHDR", <<width::32, 4::32, 8, 2, 0, 0, 0>>) <>
      chunk.("IDAT", :zlib.compress(rows)) <> chunk.("IEND", "")
  end

  defp inputs(id) do
    assigns = %{
      id: id,
      customer: %{name: "Customer #{id}"},
      items: for(n <- 1..(rem(id, 5) + 1), do: %{name: "Item #{id}-#{n}", price: Decimal.new("#{id}.#{n}")})
    }

    files = %{
      "logo.png" => png(id),
      "data.json" => JSON.encode!(%{id: id, notes: for(n <- 1..(rem(id, 3) + 1), do: "note #{id}.#{n}")}),
      "lib.typ" => ~s(#let tag = "lib-#{id}")
    }

    {assigns, files}
  end

  defp render(format, id) do
    {assigns, files} = inputs(id)
    apply(Invoice, :"to_#{format}", [assigns, [files: files, ppi: 72]])
  end

  @ids 1..120

  for format <- [:pdf, :png, :svg] do
    test "concurrent #{format} renders match the same renders done one at a time" do
      format = unquote(format)
      expected = Map.new(@ids, &{&1, render(format, &1)})

      # Every render is different, so a mixed-up file or variable would show
      assert expected |> Map.values() |> Enum.uniq() |> length() == Enum.count(@ids)
      assert Enum.all?(Map.values(expected), &match?({:ok, _}, &1))

      # Each id is rendered several times, interleaved with the others
      jobs = for _round <- 1..4, id <- Enum.shuffle(@ids), do: id

      jobs
      |> Task.async_stream(&{&1, render(format, &1)}, max_concurrency: 48, ordered: false, timeout: :infinity)
      |> Enum.each(fn {:ok, {id, result}} -> assert result == expected[id], "render #{id} differs" end)
    end
  end

  test "concurrent errors point at their own template and file" do
    jobs =
      for id <- 1..200 do
        # The same file name with different contents, some of them broken
        broken? = rem(id, 3) == 0
        lib = if broken?, do: "#let tag = missing-#{id}", else: ~s(#let tag = "ok-#{id}")
        source = ~s(#import "lib.typ": tag\n#tag #value-#{rem(id, 2)})
        {id, broken?, source, lib}
      end

    jobs
    |> Task.async_stream(
      fn {id, broken?, source, lib} ->
        result = Typsty.to_svg(source, %{"value-0" => "zero", "value-1" => "one"}, files: %{"lib.typ" => lib})
        {id, broken?, result}
      end,
      max_concurrency: 48,
      timeout: :infinity
    )
    |> Enum.each(fn
      {:ok, {id, true, result}} ->
        assert {:error, %Typsty.RenderError{diagnostics: [diagnostic]}} = result
        assert diagnostic.message == "unknown variable: missing-#{id}"
        assert {diagnostic.file, diagnostic.line} == {"/lib.typ", 1}

      {:ok, {_id, false, result}} ->
        assert {:ok, [_svg]} = result
    end)
  end
end
